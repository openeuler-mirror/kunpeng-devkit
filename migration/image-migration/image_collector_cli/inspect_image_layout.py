#!/usr/bin/env python3
# =============================================================================
# inspect_image_layout.py
#
# 对一个（或多个）Docker 镜像快速扫描其内部结构和组件，导出 JSON。
#
# 三种采集模式（--mode）：
#   rebuild  [默认] 重构镜像专用：OS / 环境变量 / 语言运行时 / 系统包 /
#                   pip包 / 关键配置文件 / 用户 / libc / 项目文件
#                   → 不含 directory_tree / executables，文件小速度快
#   normal           rebuild 基础上 + executables（PATH下可执行文件）
#   full             全量，包含 directory_tree（文件/目录遍历，可能很大）
#
# 用法：
#   python3 inspect_image_layout.py <image> [<image2> ...]
#   python3 inspect_image_layout.py --images-file images.txt
#   python3 inspect_image_layout.py <image> --output /path/to/out.json --pretty
#   python3 inspect_image_layout.py <image> --output-dir /path/to/dir/
#   python3 inspect_image_layout.py <image> --mode full --depth 3
#   python3 inspect_image_layout.py --images-file images.txt --workers 8 --output-dir ./out/
#
# 可选参数：
#   --mode MODE        采集模式：rebuild（默认）/ normal / full
#   --depth N          目录树最大深度，仅 full 模式生效，默认 3
#   --scan-dirs DIRS   逗号或空格分隔的扫描根目录（full 模式用）
#   --timeout N        单容器超时秒数，默认 120
#   --workers N        并发数，默认 4（批量模式生效）
#   --pretty           输出缩进格式化 JSON（默认紧凑）
#   --output FILE      单镜像结果写入指定文件（仅单镜像时生效）
#   --output-dir DIR   多镜像结果写入该目录（每个镜像一个 JSON 文件 + summary.json）
#   --images-file FILE 从文件读取镜像名（每行一个，# 开头为注释）
#
# 依赖：仅 Python 3.6+ 标准库 + docker CLI
# =============================================================================

import argparse
import base64
import json
import re
import subprocess
import sys
import textwrap
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# --------------------------------------------------------------------------
# 注入到容器内执行的 shell 脚本（/bin/sh 兼容，不依赖 bash）
# 环境变量控制：
#   SKIP_PACKAGES=1   跳过系统包 / pip 包采集
#   SKIP_EXECUTABLES=1 跳过 PATH 可执行文件列表
#   SKIP_TREE=1       跳过目录树
#   SCAN_DIRS="..."   目录树根目录（空格分隔）
#   TREE_DEPTH=N      目录树深度
# --------------------------------------------------------------------------
_INNER_SCRIPT = r"""#!/bin/sh
set +e

# ---- 工具函数 ----
jesc() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed 's/	/\\t/g' \
        | tr -d '\r'
}

cmd_ver() {
    local _c="$1"
    if command -v "$_c" >/dev/null 2>&1; then
        "$_c" --version 2>/dev/null | head -1 \
            || "$_c" version  2>/dev/null | head -1 \
            || echo "installed"
    else
        echo ""
    fi
}

# ================================================================
# 1. OS 信息
# ================================================================
_os_name="" _os_ver="" _os_id="" _os_pretty="" _os_id_like=""
if [ -f /etc/os-release ]; then
    _os_name=$(  grep '^NAME='        /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_ver=$(   grep '^VERSION='     /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_id=$(    grep '^ID='          /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_pretty=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_id_like=$(grep '^ID_LIKE='    /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
elif [ -f /etc/lsb-release ]; then
    _os_name=$(grep '^DISTRIB_ID='      /etc/lsb-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_ver=$( grep '^DISTRIB_RELEASE=' /etc/lsb-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
elif [ -f /etc/alpine-release ]; then
    _os_id="alpine"
    _os_ver=$(cat /etc/alpine-release 2>/dev/null | head -1)
    _os_name="Alpine Linux"
    _os_pretty="Alpine Linux ${_os_ver}"
fi
_arch=$(uname -m 2>/dev/null || true)
_kernel=$(uname -r 2>/dev/null || true)
_uname=$(uname -srm 2>/dev/null || true)

printf '{"os":{'
printf '"name":"%s",'        "$(jesc "$_os_name")"
printf '"version":"%s",'     "$(jesc "$_os_ver")"
printf '"id":"%s",'          "$(jesc "$_os_id")"
printf '"id_like":"%s",'     "$(jesc "$_os_id_like")"
printf '"pretty_name":"%s",' "$(jesc "$_os_pretty")"
printf '"arch":"%s",'        "$(jesc "$_arch")"
printf '"kernel":"%s",'      "$(jesc "$_kernel")"
printf '"uname":"%s"'        "$(jesc "$_uname")"
printf '},'

# ================================================================
# 2. 环境变量（容器运行时 env，来自 Dockerfile ENV 指令）
# ================================================================
printf '"env_vars":{'
_ef=1
while IFS= read -r _line; do
    _k=$(printf '%s' "$_line" | cut -d= -f1)
    _v=$(printf '%s' "$_line" | cut -d= -f2-)
    case "$_k" in PWD|OLDPWD|SHLVL|_) continue ;; esac
    [ -z "$_k" ] && continue
    [ "$_ef" -eq 1 ] && _ef=0 || printf ','
    printf '"%s":"%s"' "$(jesc "$_k")" "$(jesc "$_v")"
done << __ENVEOF__
$(env | sort 2>/dev/null)
__ENVEOF__
printf '},'

# ================================================================
# 3. 语言运行时版本
# ================================================================
printf '"runtimes":{'
printf '"python3":"%s",'    "$(jesc "$(cmd_ver python3)")"
printf '"python":"%s",'     "$(jesc "$(cmd_ver python)")"
printf '"pip3":"%s",'       "$(jesc "$(cmd_ver pip3)")"
printf '"pip":"%s",'        "$(jesc "$(cmd_ver pip)")"
printf '"conda":"%s",'      "$(jesc "$(cmd_ver conda)")"
printf '"uv":"%s",'         "$(jesc "$(cmd_ver uv)")"
printf '"poetry":"%s",'     "$(jesc "$(cmd_ver poetry)")"
printf '"node":"%s",'       "$(jesc "$(cmd_ver node)")"
printf '"npm":"%s",'        "$(jesc "$(cmd_ver npm)")"
printf '"yarn":"%s",'       "$(jesc "$(cmd_ver yarn)")"
printf '"pnpm":"%s",'       "$(jesc "$(cmd_ver pnpm)")"
printf '"bun":"%s",'        "$(jesc "$(cmd_ver bun)")"
printf '"deno":"%s",'       "$(jesc "$(cmd_ver deno)")"
printf '"tsc":"%s",'        "$(jesc "$(cmd_ver tsc)")"
printf '"go":"%s",'         "$(jesc "$(cmd_ver go)")"
printf '"java":"%s",'       "$(jesc "$(cmd_ver java)")"
printf '"javac":"%s",'      "$(jesc "$(cmd_ver javac)")"
printf '"mvn":"%s",'        "$(jesc "$(cmd_ver mvn)")"
printf '"gradle":"%s",'     "$(jesc "$(cmd_ver gradle)")"
printf '"sbt":"%s",'        "$(jesc "$(cmd_ver sbt)")"
printf '"scala":"%s",'      "$(jesc "$(cmd_ver scala)")"
printf '"kotlin":"%s",'     "$(jesc "$(cmd_ver kotlinc)")"
printf '"ruby":"%s",'       "$(jesc "$(cmd_ver ruby)")"
printf '"gem":"%s",'        "$(jesc "$(cmd_ver gem)")"
printf '"bundle":"%s",'     "$(jesc "$(cmd_ver bundle)")"
printf '"rustc":"%s",'      "$(jesc "$(cmd_ver rustc)")"
printf '"cargo":"%s",'      "$(jesc "$(cmd_ver cargo)")"
printf '"rustup":"%s",'     "$(jesc "$(cmd_ver rustup)")"
printf '"php":"%s",'        "$(jesc "$(cmd_ver php)")"
printf '"composer":"%s",'   "$(jesc "$(cmd_ver composer)")"
printf '"dotnet":"%s",'     "$(jesc "$(cmd_ver dotnet)")"
printf '"gcc":"%s",'        "$(jesc "$(cmd_ver gcc)")"
printf '"gxx":"%s",'        "$(jesc "$(cmd_ver g++)")"
printf '"clang":"%s",'      "$(jesc "$(cmd_ver clang)")"
printf '"cmake":"%s",'      "$(jesc "$(cmd_ver cmake)")"
printf '"perl":"%s",'       "$(jesc "$(cmd_ver perl)")"
printf '"lua":"%s",'        "$(jesc "$(cmd_ver lua)")"
printf '"swift":"%s",'      "$(jesc "$(cmd_ver swift)")"
printf '"R":"%s",'          "$(jesc "$(cmd_ver Rscript)")"
printf '"elixir":"%s",'     "$(jesc "$(cmd_ver elixir)")"
printf '"erlang":"%s",'     "$(jesc "$(cmd_ver erl)")"
printf '"make":"%s",'       "$(jesc "$(cmd_ver make)")"
printf '"ninja":"%s",'      "$(jesc "$(cmd_ver ninja)")"
printf '"bazel":"%s",'      "$(jesc "$(cmd_ver bazel)")"
printf '"git":"%s",'        "$(jesc "$(cmd_ver git)")"
printf '"curl":"%s",'       "$(jesc "$(cmd_ver curl)")"
printf '"wget":"%s",'       "$(jesc "$(cmd_ver wget)")"
printf '"protoc":"%s"'      "$(jesc "$(cmd_ver protoc)")"
printf '},'

# ================================================================
# 4. 系统包列表
# ================================================================
_pkg_mgr="" _pkg_count=0 _pkgs=""
if [ "${SKIP_PACKAGES:-0}" != "1" ]; then
    if command -v dpkg >/dev/null 2>&1; then
        _pkg_mgr="dpkg"
        _pkgs=$(dpkg -l 2>/dev/null | awk '/^ii/{if(c++)printf ","; printf "\"%s==%s\"", $2,$3}' 2>/dev/null || true)
        _pkg_count=$(dpkg -l 2>/dev/null | grep -c '^ii' 2>/dev/null || echo 0)
    elif command -v rpm >/dev/null 2>&1; then
        _pkg_mgr="rpm"
        _pkgs=$(rpm -qa --queryformat '%{NAME}==%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort \
            | awk '{if(c++)printf ","; printf "\"%s\"", $0}' 2>/dev/null || true)
        _pkg_count=$(rpm -qa 2>/dev/null | grep -c . 2>/dev/null || echo 0)
    elif command -v apk >/dev/null 2>&1; then
        _pkg_mgr="apk"
        _pkgs=$(apk info -v 2>/dev/null | sort \
            | awk '{if(c++)printf ","; printf "\"%s\"", $1}' 2>/dev/null || true)
        _pkg_count=$(apk info -v 2>/dev/null | grep -c . 2>/dev/null || echo 0)
    fi
fi
printf '"packages":{"manager":"%s","count":%s,"list":[%s]},' \
    "$(jesc "$_pkg_mgr")" "$_pkg_count" "$_pkgs"

# ================================================================
# 5. pip 已安装包
# ================================================================
_pip_pkgs="" _pip_cmd=""
if command -v pip3 >/dev/null 2>&1; then _pip_cmd="pip3"
elif command -v pip >/dev/null 2>&1; then _pip_cmd="pip"
fi
if [ -n "$_pip_cmd" ] && [ "${SKIP_PACKAGES:-0}" != "1" ]; then
    _pip_pkgs=$("$_pip_cmd" list --format=columns 2>/dev/null \
        | tail -n +3 \
        | awk '{if(c++)printf ","; printf "\"%s==%s\"", $1, $2}' \
        2>/dev/null || true)
fi
printf '"pip_packages":[%s],' "$_pip_pkgs"

# ================================================================
# 6. 关键配置文件内容（apt源/profile/hosts等，重构镜像必需）
# ================================================================
printf '"key_files":{'
_kffirst=1
for _kf in \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d/*.list \
    /etc/apk/repositories \
    /etc/yum.repos.d/*.repo \
    /etc/profile \
    /etc/profile.d/*.sh \
    /etc/environment \
    /etc/shells \
    /etc/hosts \
    /etc/hostname \
    /etc/ld.so.conf \
    /etc/ld.so.conf.d/*.conf \
    /etc/security/limits.conf; do
    [ -f "$_kf" ] || continue
    _content=$(head -60 "$_kf" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || true)
    [ -z "$_content" ] && continue
    [ "$_kffirst" -eq 1 ] && _kffirst=0 || printf ','
    printf '"%s":"%s"' "$(jesc "$_kf")" "$(jesc "$_content")"
done
printf '},'

# ================================================================
# 7. 项目特征文件检测（应用入口、依赖声明文件）
# ================================================================
printf '"project_files":{'
_pffirst=1
for _search_dir in / /app /workspace /code /project /srv /opt /home /testbed; do
    [ -d "$_search_dir" ] || continue
    for _pat in \
        requirements.txt setup.py pyproject.toml setup.cfg Pipfile \
        package.json yarn.lock pnpm-lock.yaml \
        go.mod Cargo.toml \
        pom.xml build.gradle build.gradle.kts \
        Gemfile composer.json \
        Makefile CMakeLists.txt \
        Dockerfile docker-compose.yml docker-compose.yaml \
        supervisord.conf nginx.conf \
        .env .env.example; do
        _full="${_search_dir}/${_pat}"
        [ -f "$_full" ] || continue
        _fc=$(head -30 "$_full" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || true)
        [ "$_pffirst" -eq 1 ] && _pffirst=0 || printf ','
        printf '"%s":"%s"' "$(jesc "$_full")" "$(jesc "$_fc")"
    done
done
printf '},'

# ================================================================
# 8. 用户信息
# ================================================================
_users=""
if [ -f /etc/passwd ]; then
    _users=$(cut -d: -f1,3,6,7 /etc/passwd 2>/dev/null | head -40 \
        | awk -F: 'NR>1{printf ","} {printf "{\"user\":\"%s\",\"uid\":\"%s\",\"home\":\"%s\",\"shell\":\"%s\"}", $1,$2,$3,$4}' \
        2>/dev/null || true)
fi
printf '"users":[%s],' "$_users"

# ================================================================
# 9. libc 类型
# ================================================================
_libc_type="" _libc_ver=""
for _lp in \
    /lib/x86_64-linux-gnu/libc.so.6 \
    /lib/aarch64-linux-gnu/libc.so.6 \
    /lib/i386-linux-gnu/libc.so.6 \
    /lib/libc.so.6 /lib64/libc.so.6; do
    if [ -f "$_lp" ]; then
        _libc_type="glibc"
        _libc_ver=$(strings "$_lp" 2>/dev/null | grep '^GNU C Library' | head -1 || true)
        break
    fi
done
if [ -z "$_libc_type" ]; then
    for _mp in \
        /lib/ld-musl-x86_64.so.1 /lib/ld-musl-aarch64.so.1 \
        /lib/ld-musl-armhf.so.1  /lib/ld-musl-arm64.so.1; do
        [ -f "$_mp" ] && _libc_type="musl" && break
    done
fi
if [ -z "$_libc_type" ] && command -v ldd >/dev/null 2>&1; then
    _ldd_out=$(ldd --version 2>/dev/null | head -1 || true)
    case "$_ldd_out" in
        *musl*)          _libc_type="musl"  ; _libc_ver="$_ldd_out" ;;
        *GLIBC*|*glibc*) _libc_type="glibc" ; _libc_ver="$_ldd_out" ;;
    esac
fi
printf '"libc":{"type":"%s","version":"%s"},' \
    "$(jesc "$_libc_type")" "$(jesc "$_libc_ver")"

# ================================================================
# 10. PATH 下所有可执行文件（normal/full 模式）
# ================================================================
if [ "${SKIP_EXECUTABLES:-1}" != "1" ]; then
    printf '"executables":['
    _befirst=1 _seen_bins=""
    for _bindir in $(printf '%s' "$PATH" | tr ':' '\n' | sort -u 2>/dev/null); do
        [ -d "$_bindir" ] || continue
        for _bin in "$_bindir"/*; do
            [ -f "$_bin" ] && [ -x "$_bin" ] || continue
            _bname=$(basename "$_bin")
            case "$_seen_bins" in *"|${_bname}|"*) continue ;; esac
            _seen_bins="${_seen_bins}|${_bname}|"
            [ "$_befirst" -eq 1 ] && _befirst=0 || printf ','
            printf '"%s"' "$(jesc "$_bname")"
        done
    done
    printf '],'
else
    printf '"executables":null,'
fi

# ================================================================
# 11. 目录树（full 模式）
# ================================================================
_scan_dirs="${SCAN_DIRS:-/app /opt /home /etc /srv /data /workspace /code /project}"
_depth="${TREE_DEPTH:-3}"

if [ "${SKIP_TREE:-1}" != "1" ]; then
    printf '"directory_tree":{'
    _dtfirst=1
    for _root in $_scan_dirs; do
        [ -d "$_root" ] || continue
        [ "$_dtfirst" -eq 1 ] && _dtfirst=0 || printf ','
        printf '"%s":[' "$(jesc "$_root")"
        _tffirst=1
        find "$_root" -maxdepth "$_depth" \
            ! -path '*/proc/*' ! -path '*/sys/*' ! -path '*/dev/*' \
            ! -path '*/.git/*' ! -path '*/node_modules/*' \
            ! -path '*/vendor/*' ! -path '*/target/debug/*' \
            ! -path '*/target/release/*' \
            2>/dev/null | sort | while IFS= read -r _entry; do
            [ "$_tffirst" -eq 1 ] && _tffirst=0 || printf ','
            if [ -L "$_entry" ]; then
                _lt=$(readlink "$_entry" 2>/dev/null || true)
                printf '{"path":"%s","type":"symlink","link_to":"%s"}' \
                    "$(jesc "$_entry")" "$(jesc "$_lt")"
            elif [ -d "$_entry" ]; then
                printf '{"path":"%s","type":"dir"}' "$(jesc "$_entry")"
            elif [ -f "$_entry" ]; then
                _fsz=$(wc -c < "$_entry" 2>/dev/null | tr -d ' ' || echo 0)
                printf '{"path":"%s","type":"file","size_bytes":%s}' \
                    "$(jesc "$_entry")" "$_fsz"
            fi
        done
        printf ']'
    done
    printf '},'
else
    printf '"directory_tree":null,'
fi

# ================================================================
# 12. 非包管理器安装的自定义工具（/opt 目录探测 + 特征路径检测）
# ================================================================
printf '"custom_tools":{'

# -- /opt 下一级目录，通常是手工安装的组件 --
printf '"opt_dirs":['
_odcnt=0
if [ -d /opt ]; then
    for _od in /opt/*/; do
        [ -d "$_od" ] || continue
        _odn=$(basename "$_od")
        [ "$_odcnt" -gt 0 ] && printf ','
        printf '"%s"' "$(jesc "$_odn")"
        _odcnt=$((_odcnt+1))
    done
fi
printf '],'

# -- Android SDK --
_android_ver="" _android_tools="" _android_platforms=""
_android_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"
if [ -d "$_android_home" ]; then
    # cmdline-tools 版本
    if [ -f "$_android_home/cmdline-tools/latest/bin/sdkmanager" ]; then
        _android_ver=$("$_android_home/cmdline-tools/latest/bin/sdkmanager" --version 2>/dev/null | head -1 || echo "installed")
    fi
    # 已安装 platforms
    if [ -d "$_android_home/platforms" ]; then
        _android_platforms=$(ls "$_android_home/platforms" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    fi
    # 已安装 build-tools
    if [ -d "$_android_home/build-tools" ]; then
        _android_tools=$(ls "$_android_home/build-tools" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    fi
fi
printf '"android_sdk":{"home":"%s","cmdline_tools_version":"%s","platforms":"%s","build_tools":"%s"},' \
    "$(jesc "$_android_home")" "$(jesc "$_android_ver")" \
    "$(jesc "$_android_platforms")" "$(jesc "$_android_tools")"

# -- SDKMAN 管理的候选版本 --
printf '"sdkman":{'
_sdkdir="${SDKMAN_DIR:-/opt/sdkman}"
if [ -d "$_sdkdir/candidates" ]; then
    _smfirst=1
    for _cand in "$_sdkdir/candidates"/*/; do
        [ -d "$_cand" ] || continue
        _cname=$(basename "$_cand")
        _versions=$(ls "$_cand" 2>/dev/null | grep -v '^current$' | tr '\n' ',' | sed 's/,$//')
        [ "$_smfirst" -eq 1 ] && _smfirst=0 || printf ','
        printf '"%s":"%s"' "$(jesc "$_cname")" "$(jesc "$_versions")"
    done
fi
printf '},'

# -- NVM 管理的 Node 版本 --
_nvm_dir="${NVM_DIR:-/root/.nvm}"
_nvm_versions=""
if [ -d "$_nvm_dir/versions/node" ]; then
    _nvm_versions=$(ls "$_nvm_dir/versions/node" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi
printf '"nvm":{"dir":"%s","node_versions":"%s"},' \
    "$(jesc "$_nvm_dir")" "$(jesc "$_nvm_versions")"

# -- pyenv --
_pyenv_dir="${PYENV_ROOT:-/root/.pyenv}"
_pyenv_versions=""
if [ -d "$_pyenv_dir/versions" ]; then
    _pyenv_versions=$(ls "$_pyenv_dir/versions" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi
printf '"pyenv":{"dir":"%s","versions":"%s"},' \
    "$(jesc "$_pyenv_dir")" "$(jesc "$_pyenv_versions")"

# -- rbenv / rvm --
_rbenv_dir="${RBENV_ROOT:-/root/.rbenv}"
_rbenv_versions=""
if [ -d "$_rbenv_dir/versions" ]; then
    _rbenv_versions=$(ls "$_rbenv_dir/versions" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi
printf '"rbenv":{"dir":"%s","versions":"%s"},' \
    "$(jesc "$_rbenv_dir")" "$(jesc "$_rbenv_versions")"

# -- Go 安装路径 --
_goroot="${GOROOT:-$(go env GOROOT 2>/dev/null || true)}"
_gopath="${GOPATH:-$(go env GOPATH 2>/dev/null || true)}"
printf '"golang":{"goroot":"%s","gopath":"%s"},' \
    "$(jesc "$_goroot")" "$(jesc "$_gopath")"

# -- Rust toolchains --
_rustup_home="${RUSTUP_HOME:-/root/.rustup}"
_cargo_home="${CARGO_HOME:-/root/.cargo}"
_rust_toolchains=""
if [ -d "$_rustup_home/toolchains" ]; then
    _rust_toolchains=$(ls "$_rustup_home/toolchains" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
fi
printf '"rust":{"rustup_home":"%s","cargo_home":"%s","toolchains":"%s"},' \
    "$(jesc "$_rustup_home")" "$(jesc "$_cargo_home")" "$(jesc "$_rust_toolchains")"

# -- /usr/local 下自安装的二进制工具（只列第一级，不含 bin/lib/share 本身）--
printf '"usr_local_apps":['
_ulcnt=0
if [ -d /usr/local ]; then
    for _uld in /usr/local/*/; do
        [ -d "$_uld" ] || continue
        _uln=$(basename "$_uld")
        case "$_uln" in bin|lib|lib64|share|include|sbin|src|etc|man) continue ;; esac
        [ "$_ulcnt" -gt 0 ] && printf ','
        printf '"%s"' "$(jesc "$_uln")"
        _ulcnt=$((_ulcnt+1))
    done
fi
printf ']'

printf '},'

# ================================================================
# 13. 磁盘使用 / 挂载点
# ================================================================
_df_out=$(df -h 2>/dev/null | awk \
    'NR>2{printf ","} NR>1{printf "{\"fs\":\"%s\",\"size\":\"%s\",\"used\":\"%s\",\"avail\":\"%s\",\"pct\":\"%s\",\"mount\":\"%s\"}", $1,$2,$3,$4,$5,$NF}' \
    2>/dev/null || true)
printf '"disk_usage":[%s]' "$_df_out"

printf '}'
"""


# --------------------------------------------------------------------------
# 模式 → 控制变量映射
# --------------------------------------------------------------------------
_MODE_FLAGS = {
    "rebuild": {"SKIP_PACKAGES": "0", "SKIP_EXECUTABLES": "1", "SKIP_TREE": "1"},
    "normal":  {"SKIP_PACKAGES": "0", "SKIP_EXECUTABLES": "0", "SKIP_TREE": "1"},
    "full":    {"SKIP_PACKAGES": "0", "SKIP_EXECUTABLES": "0", "SKIP_TREE": "0"},
}


# --------------------------------------------------------------------------
# 宿主机侧：docker inspect 获取镜像元信息
# --------------------------------------------------------------------------

def host_image_meta(image: str) -> dict:
    try:
        raw = subprocess.check_output(
            ["docker", "image", "inspect", image],
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        data = json.loads(raw)
        if not data:
            return {}
        info = data[0]
        cfg = info.get("Config", {})
        return {
            "id": info.get("Id", ""),
            "repo_tags": info.get("RepoTags", []),
            "repo_digests": info.get("RepoDigests", []),
            "created": info.get("Created", ""),
            "size_bytes": info.get("Size", 0),
            "size_mb": round(info.get("Size", 0) / 1024 / 1024, 1),
            "architecture": info.get("Architecture", ""),
            "os": info.get("Os", ""),
            "author": info.get("Author", ""),
            "entrypoint": cfg.get("Entrypoint") or [],
            "cmd": cfg.get("Cmd") or [],
            "working_dir": cfg.get("WorkingDir", ""),
            "exposed_ports": list((cfg.get("ExposedPorts") or {}).keys()),
            "volumes": list((cfg.get("Volumes") or {}).keys()),
            "labels": cfg.get("Labels") or {},
            "user": cfg.get("User", ""),
            "env": cfg.get("Env") or [],
            "layers": len(info.get("RootFS", {}).get("Layers", [])),
        }
    except Exception as e:
        return {"error": str(e)}


# --------------------------------------------------------------------------
# 在容器内运行采集脚本
# --------------------------------------------------------------------------

def run_inner_script(
    image: str,
    timeout: int = 120,
    mode: str = "rebuild",
    scan_dirs: str = "/app /opt /home /etc /srv /data /workspace /code /project",
    tree_depth: int = 3,
):
    flags = _MODE_FLAGS.get(mode, _MODE_FLAGS["rebuild"])
    b64 = base64.b64encode(_INNER_SCRIPT.encode("utf-8")).decode("ascii")

    env_prefix = (
        f"SKIP_PACKAGES={flags['SKIP_PACKAGES']} "
        f"SKIP_EXECUTABLES={flags['SKIP_EXECUTABLES']} "
        f"SKIP_TREE={flags['SKIP_TREE']} "
        f"SCAN_DIRS='{scan_dirs}' "
        f"TREE_DEPTH={tree_depth} "
    )
    cmd = [
        "docker", "run", "--rm",
        "--entrypoint", "/bin/sh",
        "--memory", "512m",
        "--network", "none",
        image,
        "-c",
        f"printf '%s' '{b64}' | base64 -d | {env_prefix}sh",
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=timeout, errors="replace",
        )
        return result.stdout.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "", -124
    except Exception:
        return "", -1


# --------------------------------------------------------------------------
# 解析容器内输出的 JSON
# --------------------------------------------------------------------------

def parse_inner_json(raw: str):
    if not raw:
        return {}, "empty output from container"
    try:
        return json.loads(raw), None
    except json.JSONDecodeError as e:
        idx = raw.find("{")
        if idx > 0:
            try:
                return json.loads(raw[idx:]), None
            except Exception:
                pass
        return {"raw_output": raw[:2000]}, f"JSON parse error: {e}"


# --------------------------------------------------------------------------
# 核心：采集单个镜像
# --------------------------------------------------------------------------

def inspect_image(
    image: str,
    timeout: int = 120,
    mode: str = "rebuild",
    scan_dirs: str = "/app /opt /home /etc /srv /data /workspace /code /project",
    tree_depth: int = 3,
) -> dict:
    collected_at = datetime.now(timezone.utc).isoformat()

    print(f"  [*] docker inspect ...", file=sys.stderr)
    img_meta = host_image_meta(image)

    print(f"  [*] 启动容器采集 (mode={mode}) ...", file=sys.stderr)
    raw, ec = run_inner_script(image, timeout=timeout, mode=mode,
                               scan_dirs=scan_dirs, tree_depth=tree_depth)

    if ec == -124:
        status, inner, error_msg = "timeout", {}, f"timed out after {timeout}s"
    elif ec != 0 or not raw:
        status, inner, error_msg = "error", {}, f"container exit code {ec}"
    else:
        inner, parse_err = parse_inner_json(raw)
        if parse_err:
            status, error_msg = "json_error", parse_err
        else:
            status, error_msg = "ok", None

    result = {
        "meta": {
            "source_image": image,
            "collected_at": collected_at,
            "mode": mode,
            "status": status,
            "collector": "inspect_image_layout.py",
            **({"error": error_msg} if error_msg else {}),
        },
        "image_info": img_meta,
    }
    result.update(inner)
    return result


# --------------------------------------------------------------------------
# 工具函数
# --------------------------------------------------------------------------

def safe_filename(image: str) -> str:
    return re.sub(r"[:/\\<>|?* ]", "_", image) + ".json"


def load_images_from_file(path: str):
    images = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if line:
                images.append(line)
    return images


def check_docker() -> bool:
    try:
        subprocess.check_output(["docker", "info"], stderr=subprocess.DEVNULL, timeout=10)
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="采集 Docker 镜像内部组件信息，导出 JSON（面向镜像重构）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            采集模式说明：
              rebuild  [默认] 重构镜像专用：OS/运行时/系统包/pip/配置文件/用户/libc
                              不含 directory_tree 和 executables，文件小、速度快
              normal           rebuild + executables（PATH下可执行文件列表）
              full             全量，含 directory_tree（文件遍历，文件可能很大）

            示例：
              # 默认 rebuild 模式，写入文件
              python3 inspect_image_layout.py myimage:latest -o result.json --pretty

              # normal 模式，含可执行文件列表
              python3 inspect_image_layout.py myimage:latest --mode normal --pretty

              # full 模式，只扫 /app /opt 目录，深度3
              python3 inspect_image_layout.py myimage:latest --mode full --scan-dirs /app,/opt --depth 3

              # 批量采集，8 并发，写入目录
              python3 inspect_image_layout.py --images-file images.txt -d ./results/ --workers 8 --pretty
        """),
    )
    parser.add_argument("images", nargs="*", metavar="IMAGE", help="镜像名（可多个）")
    parser.add_argument("--images-file", "-f", metavar="FILE",
                        help="从文件读取镜像名（每行一个，# 开头为注释）")
    parser.add_argument("--output", "-o", metavar="FILE",
                        help="单镜像结果输出文件（仅单镜像时生效）")
    parser.add_argument("--output-dir", "-d", metavar="DIR",
                        help="结果输出目录（每镜像一个 JSON 文件 + summary.json）")
    parser.add_argument("--mode", default="rebuild",
                        choices=["rebuild", "normal", "full"],
                        help="采集模式：rebuild（默认）/ normal / full")
    parser.add_argument("--depth", type=int, default=3, metavar="N",
                        help="目录树深度，仅 full 模式生效（默认 3）")
    parser.add_argument("--scan-dirs",
                        default="/app /opt /home /etc /srv /data /workspace /code /project",
                        metavar="DIRS",
                        help="目录树扫描根目录（逗号或空格分隔，仅 full 模式生效）")
    parser.add_argument("--timeout", type=int, default=120, metavar="N",
                        help="单容器超时秒数（默认 120）")
    parser.add_argument("--workers", type=int, default=4, metavar="N",
                        help="并发数，批量采集时生效（默认 4）")
    parser.add_argument("--pretty", action="store_true",
                        help="输出缩进格式化 JSON（默认紧凑）")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    images = list(args.images)
    if args.images_file:
        images.extend(load_images_from_file(args.images_file))

    if not images:
        parser.print_help()
        print("\n[ERROR] 请至少提供一个镜像名，或通过 --images-file 指定", file=sys.stderr)
        sys.exit(1)

    print("[INFO] 检查 Docker 环境...", file=sys.stderr)
    if not check_docker():
        print("[ERROR] Docker daemon 未运行或无权限访问", file=sys.stderr)
        sys.exit(1)

    scan_dirs_raw = args.scan_dirs.replace(",", " ")
    total = len(images)
    workers = min(args.workers, total)

    out_dir: Optional[Path] = None
    if args.output_dir:
        out_dir = Path(args.output_dir)
        out_dir.mkdir(parents=True, exist_ok=True)

    json_kwargs = {"ensure_ascii": False, "indent": 2} if args.pretty else {"ensure_ascii": False}

    # 结果字典，保持原始顺序
    results_map: dict = {}
    lock_print = __import__("threading").Lock()

    def _collect(idx_image):
        idx, image = idx_image
        with lock_print:
            print(f"\n[{idx}/{total}] 采集: {image}  (mode={args.mode})", file=sys.stderr)
        result = inspect_image(
            image,
            timeout=args.timeout,
            mode=args.mode,
            scan_dirs=scan_dirs_raw,
            tree_depth=args.depth,
        )
        status = result.get("meta", {}).get("status", "?")
        with lock_print:
            print(f"[{idx}/{total}] 完成: {image}  状态={status}", file=sys.stderr)
        return image, result

    if workers > 1 and total > 1:
        print(f"[INFO] 并发采集，workers={workers}", file=sys.stderr)
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {
                executor.submit(_collect, (idx, img)): img
                for idx, img in enumerate(images, 1)
            }
            for future in as_completed(futures):
                image, result = future.result()
                results_map[image] = result
    else:
        for idx, image in enumerate(images, 1):
            image, result = _collect((idx, image))
            results_map[image] = result

    # 按原始顺序排列结果
    all_results = [results_map[img] for img in images]

    # ── 写单镜像文件（有 --output-dir 时）──
    if out_dir:
        for result in all_results:
            img_name = result.get("meta", {}).get("source_image", "unknown")
            fpath = out_dir / safe_filename(img_name)
            with open(fpath, "w", encoding="utf-8") as f:
                json.dump(result, f, **json_kwargs)
            print(f"  → {fpath}", file=sys.stderr)

        summary_path = out_dir / "summary.json"
        with open(summary_path, "w", encoding="utf-8") as f:
            json.dump(all_results, f, **json_kwargs)
        print(f"\n[DONE] 汇总: {summary_path}  共 {total} 个镜像", file=sys.stderr)
        return

    # ── 无 --output-dir 时 ──
    if total == 1:
        output_data = all_results[0]
        if args.output:
            with open(args.output, "w", encoding="utf-8") as f:
                json.dump(output_data, f, **json_kwargs)
            print(f"\n[DONE] 已写入: {args.output}", file=sys.stderr)
        else:
            print(json.dumps(output_data, **json_kwargs))
            print(f"\n[DONE] 共采集 {total} 个镜像", file=sys.stderr)
    else:
        # 多镜像但无 --output-dir：输出到 stdout（JSON array）
        if args.output:
            print("[WARN] 多镜像模式下 --output 无效，请使用 --output-dir，结果将输出到 stdout",
                  file=sys.stderr)
        print(json.dumps(all_results, **json_kwargs))
        print(f"\n[DONE] 共采集 {total} 个镜像", file=sys.stderr)


if __name__ == "__main__":
    main()
