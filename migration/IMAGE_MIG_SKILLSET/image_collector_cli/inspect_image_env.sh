#!/usr/bin/env bash
# =============================================================================
# inspect_image_env.sh
# 采集 Docker 镜像的环境信息（环境变量/OS/系统包/多语言构建环境等）
#
# 三种运行模式：
#   1. 无参数         → 自动扫描 `docker images` 所有本地镜像，批量采集
#   2. 参数是文本文件  → 从文件中逐行读取镜像名，批量采集（# 开头为注释）
#   3. 参数是镜像名   → 单镜像采集
#
# 用法：
#   bash inspect_image_env.sh                              # 扫描所有本地镜像
#   bash inspect_image_env.sh images.txt                   # 从文件读取镜像列表
#   bash inspect_image_env.sh golang:1.24                  # 单个镜像
#
# 可选环境变量：
#   OUTPUT_DIR    输出目录，默认 env_inspect_out（批量）/ 当前目录（单镜像）
#   PARALLEL      并发数，默认 4（批量模式生效）
#   TIMEOUT       单容器超时秒数，默认 120
#   FILTER        镜像名过滤关键词（grep 正则），仅自动扫描模式生效
#
# 输出结构：
#   <OUTPUT_DIR>/
#     ├── summary.json          # 所有镜像采集结果汇总（JSON Array）
#     └── images/
#         ├── <image1>.json     # 每个镜像单独的 JSON 文件（文件名=镜像名，冒号/斜杠替换为_）
#         ├── <image2>.json
#         └── ...
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# 参数解析
# --------------------------------------------------------------------------
ARG="${1:-}"            # 镜像名 / 文件路径 / 空
OUTPUT_DIR="${OUTPUT_DIR:-}"
MAX_PARALLEL="${PARALLEL:-4}"
TIMEOUT="${TIMEOUT:-120}"
FILTER="${FILTER:-}"

# --------------------------------------------------------------------------
# 日志
# --------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RESET='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_err()  { echo -e "${RED}[ERR]${RESET}   $*" >&2; }

# --------------------------------------------------------------------------
# 检查 docker
# --------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log_err "未找到 docker，请先安装"
    exit 1
fi

run_with_timeout() {
    if command -v timeout &>/dev/null; then
        timeout "$TIMEOUT" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$TIMEOUT" "$@"
    else
        "$@"
    fi
}

# --------------------------------------------------------------------------
# 将容器内采集脚本写入临时文件，base64 编码后传入容器
# --------------------------------------------------------------------------
_TMPSCRIPT=$(mktemp /tmp/inner_collect_XXXXXX.sh)
trap 'rm -f "$_TMPSCRIPT"' EXIT

cat > "$_TMPSCRIPT" << 'SCRIPT_CONTENT'
#!/bin/sh
set +e

# JSON 字符串转义
jesc() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed 's/	/\\t/g' \
        | tr -d '\r'
}

# 获取命令版本的辅助函数
cmd_ver() {
    local _cmd="$1"
    if command -v "$_cmd" >/dev/null 2>&1; then
        "$_cmd" --version 2>/dev/null | head -1 \
            || "$_cmd" version 2>/dev/null | head -1 \
            || echo "installed"
    else
        echo ""
    fi
}

# ---- 1. 环境变量 ----
printf '{"image_env":{'
_first=1
while IFS= read -r _line; do
    _key=$(printf '%s' "$_line" | cut -d= -f1)
    _val=$(printf '%s' "$_line" | cut -d= -f2-)
    case "$_key" in
        PWD|OLDPWD|SHLVL|_) continue ;;
    esac
    [ -z "$_key" ] && continue
    [ "$_first" -eq 1 ] && _first=0 || printf ','
    printf '"%s":"%s"' "$(jesc "$_key")" "$(jesc "$_val")"
done << __ENVEOF__
$(env | sort 2>/dev/null)
__ENVEOF__
printf '},'

# ---- 2. OS 信息 ----
_os_name='' ; _os_ver='' ; _os_id='' ; _os_pretty=''
if [ -f /etc/os-release ]; then
    _os_name=$(  grep '^NAME='        /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_ver=$(   grep '^VERSION='     /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_id=$(    grep '^ID='          /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_pretty=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
elif [ -f /etc/lsb-release ]; then
    _os_name=$(grep '^DISTRIB_ID='      /etc/lsb-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    _os_ver=$(  grep '^DISTRIB_RELEASE=' /etc/lsb-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
fi
_uname=$(uname -srm 2>/dev/null || true)
_kernel=$(uname -r 2>/dev/null || true)
_arch=$(uname -m 2>/dev/null || true)

printf '"os":{"name":"%s","version":"%s","id":"%s","pretty_name":"%s","kernel":"%s","arch":"%s","uname":"%s"},' \
    "$(jesc "$_os_name")" "$(jesc "$_os_ver")" "$(jesc "$_os_id")" \
    "$(jesc "$_os_pretty")" "$(jesc "$_kernel")" "$(jesc "$_arch")" "$(jesc "$_uname")"

# ---- 3. 系统包 ----
_pkg_mgr='' ; _pkg_list=''
if command -v dpkg >/dev/null 2>&1; then
    _pkg_mgr='dpkg'
    _pkg_list=$(dpkg -l 2>/dev/null | awk '/^ii/{printf "%s=%s\n", $2, $3}' | sort)
elif command -v rpm >/dev/null 2>&1; then
    _pkg_mgr='rpm'
    _pkg_list=$(rpm -qa --queryformat '%{NAME}=%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort)
elif command -v apk >/dev/null 2>&1; then
    _pkg_mgr='apk'
    _pkg_list=$(apk info -v 2>/dev/null | sort)
fi
_pkg_count=0
[ -n "$_pkg_list" ] && _pkg_count=$(printf '%s\n' "$_pkg_list" | grep -c . 2>/dev/null || echo 0)

printf '"packages":{"manager":"%s","count":%s,"list":[' "$(jesc "$_pkg_mgr")" "$_pkg_count"
_pfirst=1
printf '%s\n' "$_pkg_list" | while IFS= read -r _pkg; do
    [ -z "$_pkg" ] && continue
    [ "$_pfirst" -eq 1 ] && _pfirst=0 || printf ','
    printf '"%s"' "$(jesc "$_pkg")"
done
printf ']},'

# ---- 4. C / C++ ----
_gcc_ver=$(cmd_ver gcc)
_gxx_ver=$(cmd_ver g++)
_clang_ver=$(cmd_ver clang)
_clangxx_ver=$(cmd_ver clang++)
_cmake_ver=$(cmd_ver cmake)
_make_ver=$(cmd_ver make)
_ninja_ver=$(cmd_ver ninja)

# libc 检测
_libc_type='' ; _libc_ver=''
for _lp in /lib/x86_64-linux-gnu/libc.so.6 /lib/aarch64-linux-gnu/libc.so.6 \
           /lib/i386-linux-gnu/libc.so.6 /lib/libc.so.6; do
    if [ -f "$_lp" ]; then
        _libc_type='glibc'
        _libc_ver=$(strings "$_lp" 2>/dev/null | grep '^GNU C Library' | head -1 || true)
        break
    fi
done
if [ -z "$_libc_type" ]; then
    for _mp in /lib/ld-musl-x86_64.so.1 /lib/ld-musl-aarch64.so.1 /lib/ld-musl-armhf.so.1; do
        [ -f "$_mp" ] && _libc_type='musl' && break
    done
fi
if [ -z "$_libc_type" ] && command -v ldd >/dev/null 2>&1; then
    _ldd_out=$(ldd --version 2>/dev/null | head -1 || true)
    case "$_ldd_out" in
        *musl*)          _libc_type='musl'  ; _libc_ver="$_ldd_out" ;;
        *GLIBC*|*glibc*) _libc_type='glibc' ; _libc_ver="$_ldd_out" ;;
    esac
fi

printf '"c_cpp":{'
printf '"gcc":"%s",'       "$(jesc "$_gcc_ver")"
printf '"gxx":"%s",'       "$(jesc "$_gxx_ver")"
printf '"clang":"%s",'     "$(jesc "$_clang_ver")"
printf '"clangxx":"%s",'   "$(jesc "$_clangxx_ver")"
printf '"cmake":"%s",'     "$(jesc "$_cmake_ver")"
printf '"make":"%s",'      "$(jesc "$_make_ver")"
printf '"ninja":"%s",'     "$(jesc "$_ninja_ver")"
printf '"libc_type":"%s",' "$(jesc "$_libc_type")"
printf '"libc_version":"%s"' "$(jesc "$_libc_ver")"
printf '},'

# ---- 5. Go ----
_go_ver='' ; _go_root='' ; _go_path='' ; _go_env_full='' ; _cgo_enabled=''
if command -v go >/dev/null 2>&1; then
    _go_ver=$(go version 2>/dev/null | head -1 || true)
    _go_root=$(go env GOROOT 2>/dev/null || true)
    _go_path=$(go env GOPATH  2>/dev/null || true)
    _go_env_full=$(go env 2>/dev/null | tr '\n' '|' | sed 's/|$//' || true)
    _cgo_enabled=$(go env CGO_ENABLED 2>/dev/null || true)
fi

_gomod_path=''
if [ -f /testbed/go.mod ]; then
    _gomod_path='/testbed/go.mod'
elif [ -n "$_go_path" ] && [ -f "${_go_path}/src/go.mod" ]; then
    _gomod_path="${_go_path}/src/go.mod"
else
    _gomod_path=$(find / -maxdepth 6 -name 'go.mod' \
        ! -path '*/vendor/*' ! -path '*/.git/*' \
        2>/dev/null | head -1 || true)
fi

_gomod_content='' ; _gosum_exists=false
if [ -n "$_gomod_path" ] && [ -f "$_gomod_path" ]; then
    _gomod_content=$(head -60 "$_gomod_path" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || true)
    _gomod_dir=$(dirname "$_gomod_path")
    [ -f "${_gomod_dir}/go.sum" ] && _gosum_exists=true
fi

printf '"go":{'
printf '"version":"%s",'        "$(jesc "$_go_ver")"
printf '"goroot":"%s",'         "$(jesc "$_go_root")"
printf '"gopath":"%s",'         "$(jesc "$_go_path")"
printf '"go_env":"%s",'         "$(jesc "$_go_env_full")"
printf '"go_mod_path":"%s",'    "$(jesc "$_gomod_path")"
printf '"go_mod_content":"%s",' "$(jesc "$_gomod_content")"
printf '"go_sum_exists":%s,'    "$_gosum_exists"
printf '"cgo_enabled":"%s"'     "$(jesc "$_cgo_enabled")"
printf '},'

# ---- 6. Java ----
_java_ver=$(cmd_ver java)
_javac_ver=$(cmd_ver javac)
_mvn_ver=$(cmd_ver mvn)
_gradle_ver=$(cmd_ver gradle)
_ant_ver=$(cmd_ver ant)
_sbt_ver=$(cmd_ver sbt)
_scala_ver=$(cmd_ver scala)
_kotlin_ver=$(cmd_ver kotlinc)
_java_home="${JAVA_HOME:-}"

# 查找 pom.xml / build.gradle / build.gradle.kts
_java_build_file=''
for _jbf in /testbed/pom.xml /testbed/build.gradle /testbed/build.gradle.kts; do
    [ -f "$_jbf" ] && _java_build_file="$_jbf" && break
done
if [ -z "$_java_build_file" ]; then
    _java_build_file=$(find / -maxdepth 5 \( -name 'pom.xml' -o -name 'build.gradle' -o -name 'build.gradle.kts' \) \
        ! -path '*/.git/*' 2>/dev/null | head -1 || true)
fi

printf '"java":{'
printf '"java_version":"%s",'    "$(jesc "$_java_ver")"
printf '"javac_version":"%s",'   "$(jesc "$_javac_ver")"
printf '"java_home":"%s",'       "$(jesc "$_java_home")"
printf '"maven":"%s",'           "$(jesc "$_mvn_ver")"
printf '"gradle":"%s",'          "$(jesc "$_gradle_ver")"
printf '"ant":"%s",'             "$(jesc "$_ant_ver")"
printf '"sbt":"%s",'             "$(jesc "$_sbt_ver")"
printf '"scala":"%s",'           "$(jesc "$_scala_ver")"
printf '"kotlin":"%s",'          "$(jesc "$_kotlin_ver")"
printf '"build_file":"%s"'       "$(jesc "$_java_build_file")"
printf '},'

# ---- 7. Python ----
_py3_ver=$(cmd_ver python3)
_py2_ver=$(cmd_ver python2)
_py_ver=$(cmd_ver python)
_pip3_ver=$(cmd_ver pip3)
_pip_ver=$(cmd_ver pip)
_conda_ver=$(cmd_ver conda)
_poetry_ver=$(cmd_ver poetry)
_pipenv_ver=$(cmd_ver pipenv)
_uv_ver=$(cmd_ver uv)
_py_home="${PYTHONHOME:-}"
_py_path="${PYTHONPATH:-}"

# 查找 requirements.txt / setup.py / pyproject.toml
_py_req=''
for _pf in /testbed/requirements.txt /testbed/setup.py /testbed/pyproject.toml /testbed/setup.cfg; do
    [ -f "$_pf" ] && _py_req="$_pf" && break
done
if [ -z "$_py_req" ]; then
    _py_req=$(find / -maxdepth 5 \( -name 'requirements.txt' -o -name 'setup.py' -o -name 'pyproject.toml' \) \
        ! -path '*/.git/*' 2>/dev/null | head -1 || true)
fi

# 已安装的 pip 包（pip list）→ 输出为 JSON array
_pip_cmd=''
if command -v pip3 >/dev/null 2>&1; then _pip_cmd='pip3'
elif command -v pip >/dev/null 2>&1; then _pip_cmd='pip'
fi

printf '"python":{'
printf '"python3":"%s",'        "$(jesc "$_py3_ver")"
printf '"python2":"%s",'        "$(jesc "$_py2_ver")"
printf '"python":"%s",'         "$(jesc "$_py_ver")"
printf '"pip3":"%s",'           "$(jesc "$_pip3_ver")"
printf '"pip":"%s",'            "$(jesc "$_pip_ver")"
printf '"conda":"%s",'          "$(jesc "$_conda_ver")"
printf '"poetry":"%s",'         "$(jesc "$_poetry_ver")"
printf '"pipenv":"%s",'         "$(jesc "$_pipenv_ver")"
printf '"uv":"%s",'             "$(jesc "$_uv_ver")"
printf '"PYTHONHOME":"%s",'     "$(jesc "$_py_home")"
printf '"PYTHONPATH":"%s",'     "$(jesc "$_py_path")"
printf '"project_file":"%s",'   "$(jesc "$_py_req")"
printf '"installed_packages":['
_pipfirst=1
if [ -n "$_pip_cmd" ]; then
    "$_pip_cmd" list --format=columns 2>/dev/null | tail -n +3 | awk '{print $1"=="$2}' | \
    while IFS= read -r _ppkg; do
        [ -z "$_ppkg" ] && continue
        [ "$_pipfirst" -eq 1 ] && _pipfirst=0 || printf ','
        printf '"%s"' "$(jesc "$_ppkg")"
    done
fi
printf ']'
printf '},'

# ---- 8. Ruby ----
_ruby_ver=$(cmd_ver ruby)
_gem_ver=$(cmd_ver gem)
_bundle_ver=$(cmd_ver bundle)
_rake_ver=$(cmd_ver rake)
_rvm_ver=$(cmd_ver rvm)
_rbenv_ver=$(cmd_ver rbenv)

_ruby_gemfile=''
for _rf in /testbed/Gemfile /testbed/Gemfile.lock; do
    [ -f "$_rf" ] && _ruby_gemfile="$_rf" && break
done
if [ -z "$_ruby_gemfile" ]; then
    _ruby_gemfile=$(find / -maxdepth 5 -name 'Gemfile' ! -path '*/.git/*' 2>/dev/null | head -1 || true)
fi

printf '"ruby":{'
printf '"ruby":"%s",'    "$(jesc "$_ruby_ver")"
printf '"gem":"%s",'     "$(jesc "$_gem_ver")"
printf '"bundler":"%s",' "$(jesc "$_bundle_ver")"
printf '"rake":"%s",'    "$(jesc "$_rake_ver")"
printf '"rvm":"%s",'     "$(jesc "$_rvm_ver")"
printf '"rbenv":"%s",'   "$(jesc "$_rbenv_ver")"
printf '"gemfile":"%s"'  "$(jesc "$_ruby_gemfile")"
printf '},'

# ---- 9. Rust ----
_rustc_ver=$(cmd_ver rustc)
_cargo_ver=$(cmd_ver cargo)
_rustup_ver=$(cmd_ver rustup)
_rustfmt_ver=$(cmd_ver rustfmt)
_rust_home="${CARGO_HOME:-}"
_rustup_home="${RUSTUP_HOME:-}"

_rust_cargo_toml=''
if [ -f /testbed/Cargo.toml ]; then
    _rust_cargo_toml='/testbed/Cargo.toml'
else
    _rust_cargo_toml=$(find / -maxdepth 5 -name 'Cargo.toml' ! -path '*/.git/*' 2>/dev/null | head -1 || true)
fi

printf '"rust":{'
printf '"rustc":"%s",'        "$(jesc "$_rustc_ver")"
printf '"cargo":"%s",'        "$(jesc "$_cargo_ver")"
printf '"rustup":"%s",'       "$(jesc "$_rustup_ver")"
printf '"rustfmt":"%s",'      "$(jesc "$_rustfmt_ver")"
printf '"CARGO_HOME":"%s",'   "$(jesc "$_rust_home")"
printf '"RUSTUP_HOME":"%s",'  "$(jesc "$_rustup_home")"
printf '"cargo_toml":"%s"'    "$(jesc "$_rust_cargo_toml")"
printf '},'

# ---- 10. Node.js / JavaScript ----
_node_ver=$(cmd_ver node)
_npm_ver=$(cmd_ver npm)
_yarn_ver=$(cmd_ver yarn)
_pnpm_ver=$(cmd_ver pnpm)
_bun_ver=$(cmd_ver bun)
_deno_ver=$(cmd_ver deno)
_ts_ver=$(cmd_ver tsc)
_node_home="${NODE_HOME:-}"

_node_pkg_file=''
for _nf in /testbed/package.json /testbed/package-lock.json /testbed/yarn.lock; do
    [ -f "$_nf" ] && _node_pkg_file="$_nf" && break
done
if [ -z "$_node_pkg_file" ]; then
    _node_pkg_file=$(find / -maxdepth 5 -name 'package.json' ! -path '*/node_modules/*' ! -path '*/.git/*' 2>/dev/null | head -1 || true)
fi

printf '"nodejs":{'
printf '"node":"%s",'         "$(jesc "$_node_ver")"
printf '"npm":"%s",'          "$(jesc "$_npm_ver")"
printf '"yarn":"%s",'         "$(jesc "$_yarn_ver")"
printf '"pnpm":"%s",'         "$(jesc "$_pnpm_ver")"
printf '"bun":"%s",'          "$(jesc "$_bun_ver")"
printf '"deno":"%s",'         "$(jesc "$_deno_ver")"
printf '"typescript":"%s",'   "$(jesc "$_ts_ver")"
printf '"NODE_HOME":"%s",'    "$(jesc "$_node_home")"
printf '"package_file":"%s"'  "$(jesc "$_node_pkg_file")"
printf '},'

# ---- 11. Source code (git in /testbed) ----
_git_repo_root=''
if [ -d /testbed/.git ] || [ -f /testbed/.git ]; then
    _git_repo_root='/testbed'
fi

_git_repo_url=''
_git_commit_id=''
_git_short_commit_id=''
_git_branch=''
_git_describe=''
_git_github_url=''

if [ -n "$_git_repo_root" ] && command -v git >/dev/null 2>&1; then
    _git_repo_url=$(git -C "$_git_repo_root" config --get remote.origin.url 2>/dev/null || true)
    _git_commit_id=$(git -C "$_git_repo_root" rev-parse HEAD 2>/dev/null || true)
    _git_short_commit_id=$(git -C "$_git_repo_root" rev-parse --short HEAD 2>/dev/null || true)
    _git_branch=$(git -C "$_git_repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    _git_describe=$(git -C "$_git_repo_root" describe --tags --always --dirty 2>/dev/null || true)

    case "$_git_repo_url" in
        git@github.com:*)
            _repo_path="${_git_repo_url#git@github.com:}"
            _repo_path="${_repo_path%.git}"
            _git_github_url="https://github.com/${_repo_path}"
            ;;
        https://github.com/*)
            _git_github_url="${_git_repo_url%.git}"
            ;;
        http://github.com/*)
            _git_github_url="${_git_repo_url%.git}"
            _git_github_url="${_git_github_url/http:\/\/github.com/https:\/\/github.com}"
            ;;
    esac

    if [ -n "$_git_github_url" ] && [ -n "$_git_commit_id" ]; then
        _git_github_url="${_git_github_url}/tree/${_git_commit_id}"
    fi
fi

printf '"source_code":{'
printf '"repo_root":"%s",'        "$(jesc "$_git_repo_root")"
printf '"repo_url":"%s",'         "$(jesc "$_git_repo_url")"
printf '"commit_id":"%s",'       "$(jesc "$_git_commit_id")"
printf '"short_commit_id":"%s",' "$(jesc "$_git_short_commit_id")"
printf '"branch":"%s",'           "$(jesc "$_git_branch")"
printf '"describe":"%s",'         "$(jesc "$_git_describe")"
printf '"github_url":"%s"'        "$(jesc "$_git_github_url")"
printf '},'

# ---- 12. PHP ----
_php_ver=$(cmd_ver php)
_composer_ver=$(cmd_ver composer)
_phpunit_ver=$(cmd_ver phpunit)

_php_proj_file=''
for _pf in /testbed/composer.json /testbed/composer.lock; do
    [ -f "$_pf" ] && _php_proj_file="$_pf" && break
done
if [ -z "$_php_proj_file" ]; then
    _php_proj_file=$(find / -maxdepth 5 -name 'composer.json' ! -path '*/.git/*' 2>/dev/null | head -1 || true)
fi

printf '"php":{'
printf '"php":"%s",'       "$(jesc "$_php_ver")"
printf '"composer":"%s",'  "$(jesc "$_composer_ver")"
printf '"phpunit":"%s",'   "$(jesc "$_phpunit_ver")"
printf '"project_file":"%s"' "$(jesc "$_php_proj_file")"
printf '},'

# ---- 12. .NET / C# ----
_dotnet_ver=$(cmd_ver dotnet)
_nuget_ver=$(cmd_ver nuget)

_dotnet_proj_file=''
_dotnet_proj_file=$(find / -maxdepth 5 \( -name '*.csproj' -o -name '*.sln' -o -name '*.fsproj' \) \
    ! -path '*/.git/*' 2>/dev/null | head -1 || true)

printf '".net":{'
printf '"dotnet":"%s",'     "$(jesc "$_dotnet_ver")"
printf '"nuget":"%s",'      "$(jesc "$_nuget_ver")"
printf '"project_file":"%s"' "$(jesc "$_dotnet_proj_file")"
printf '},'

# ---- 13. 其他语言 ----
_perl_ver=$(cmd_ver perl)
_lua_ver=$(cmd_ver lua)
_lua51_ver=$(cmd_ver lua5.1)
_lua52_ver=$(cmd_ver lua5.2)
_lua53_ver=$(cmd_ver lua5.3)
_lua54_ver=$(cmd_ver lua5.4)
_swift_ver=$(cmd_ver swift)
_erlang_ver=$(cmd_ver erl)
_elixir_ver=$(cmd_ver elixir)
_mix_ver=$(cmd_ver mix)
_haskell_ver=$(cmd_ver ghc)
_cabal_ver=$(cmd_ver cabal)
_stack_ver=$(cmd_ver stack)
_r_ver=$(cmd_ver Rscript)
_julia_ver=$(cmd_ver julia)
_ocaml_ver=$(cmd_ver ocaml)
_opam_ver=$(cmd_ver opam)
_zig_ver=$(cmd_ver zig)

printf '"other_languages":{'
printf '"perl":"%s",'    "$(jesc "$_perl_ver")"
printf '"lua":"%s",'     "$(jesc "$_lua_ver")"
printf '"lua51":"%s",'   "$(jesc "$_lua51_ver")"
printf '"lua52":"%s",'   "$(jesc "$_lua52_ver")"
printf '"lua53":"%s",'   "$(jesc "$_lua53_ver")"
printf '"lua54":"%s",'   "$(jesc "$_lua54_ver")"
printf '"swift":"%s",'   "$(jesc "$_swift_ver")"
printf '"erlang":"%s",'  "$(jesc "$_erlang_ver")"
printf '"elixir":"%s",'  "$(jesc "$_elixir_ver")"
printf '"mix":"%s",'     "$(jesc "$_mix_ver")"
printf '"haskell_ghc":"%s",' "$(jesc "$_haskell_ver")"
printf '"cabal":"%s",'   "$(jesc "$_cabal_ver")"
printf '"stack":"%s",'   "$(jesc "$_stack_ver")"
printf '"R":"%s",'       "$(jesc "$_r_ver")"
printf '"julia":"%s",'   "$(jesc "$_julia_ver")"
printf '"ocaml":"%s",'   "$(jesc "$_ocaml_ver")"
printf '"opam":"%s",'    "$(jesc "$_opam_ver")"
printf '"zig":"%s"'      "$(jesc "$_zig_ver")"
printf '},'

# ---- 14. 通用构建工具 ----
_protoc_ver=$(cmd_ver protoc)
_bazel_ver=$(cmd_ver bazel)
_meson_ver=$(cmd_ver meson)
_pkg_config_ver=$(cmd_ver pkg-config)
_swig_ver=$(cmd_ver swig)

printf '"build_tools":{'
printf '"make":"%s",'        "$(jesc "$(cmd_ver make)")"
printf '"cmake":"%s",'       "$(jesc "$(cmd_ver cmake)")"
printf '"ninja":"%s",'       "$(jesc "$(cmd_ver ninja)")"
printf '"protoc":"%s",'      "$(jesc "$_protoc_ver")"
printf '"bazel":"%s",'       "$(jesc "$_bazel_ver")"
printf '"meson":"%s",'       "$(jesc "$_meson_ver")"
printf '"pkg-config":"%s",'  "$(jesc "$_pkg_config_ver")"
printf '"swig":"%s",'        "$(jesc "$_swig_ver")"
printf '"git":"%s",'         "$(jesc "$(cmd_ver git)")"
printf '"curl":"%s",'        "$(jesc "$(cmd_ver curl)")"
printf '"wget":"%s"'         "$(jesc "$(cmd_ver wget)")"
printf '},'

# ---- 15. 关键 C 库（系统级） ----
printf '"c_libs":{'
_clfirst=1
for _lib in libssl-dev libssl3 openssl-devel \
            libsqlite3-dev sqlite-libs \
            libc6-dev build-essential \
            libpcre3-dev pcre-devel \
            zlib1g-dev zlib-devel \
            libcurl4-openssl-dev libcurl-devel \
            libffi-dev libffi-devel \
            libxml2-dev libxml2-devel; do
    _found=false
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}' "$_lib" 2>/dev/null | grep -q 'install ok installed' && _found=true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -q "$_lib" >/dev/null 2>&1 && _found=true
    elif command -v apk >/dev/null 2>&1; then
        apk info "$_lib" >/dev/null 2>&1 && _found=true
    fi
    [ "$_clfirst" -eq 1 ] && _clfirst=0 || printf ','
    printf '"%s":%s' "$_lib" "$_found"
done
printf '}'

printf '}'
SCRIPT_CONTENT

INNER_SCRIPT_B64=$(base64 < "$_TMPSCRIPT" | tr -d '\n')

# --------------------------------------------------------------------------
# 核心：对单个镜像采集，返回一个 JSON 字符串（含 meta）
# --------------------------------------------------------------------------
inspect_one() {
    local image="$1"
    local idx="${2:-0}"
    local total="${3:-1}"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    local cname="envinspect_${idx}_$$"

    local raw="" ec=0
    raw=$(
        run_with_timeout docker run \
            --rm \
            --name "$cname" \
            --entrypoint /bin/sh \
            --memory 512m \
            "$image" \
            -c "printf '%s' '${INNER_SCRIPT_B64}' | base64 -d | /bin/sh" \
            2>/dev/null
    ) || ec=$?

    docker rm -f "$cname" &>/dev/null || true

    # 宿主机侧获取镜像大小（字节）
    local img_size_bytes="0"
    img_size_bytes=$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null || echo "0")

    local status="ok" errmsg=""
    if [[ $ec -eq 124 ]]; then
        status="timeout"; errmsg="timeout after ${TIMEOUT}s"
    elif [[ $ec -ne 0 ]] || [[ -z "$raw" ]]; then
        status="error";   errmsg="exit_code=${ec}"
    fi

    # 用 python3 解析 + 包装 meta，失败则降级输出原始字符串
    if [[ "$status" == "ok" ]] && command -v python3 &>/dev/null; then
        python3 -c "
import sys, json
image = sys.argv[1]; ts = sys.argv[2]; status = sys.argv[3]
size_raw = sys.argv[4]
try:
    size_bytes = int(size_raw)
    size_mb = f'{size_bytes / 1024 / 1024:.1f} MB'
except Exception:
    size_bytes = 0
    size_mb = ''
raw = sys.stdin.read().strip()
try:
    inner = json.loads(raw)
except Exception as e:
    inner = {'parse_error': str(e), 'raw': raw[:500]}
    status = 'json_error'
result = {'meta': {'source_image': image, 'collected_at': ts,
                   'status': status, 'collector': 'inspect_image_env.sh',
                   'image_size_bytes': size_bytes, 'image_size': size_mb}}
result.update(inner)
print(json.dumps(result, ensure_ascii=False))
" "$image" "$ts" "$status" "$img_size_bytes" <<< "$raw" 2>/dev/null \
        || printf '{"meta":{"source_image":"%s","collected_at":"%s","status":"json_error"}}\n' "$image" "$ts"
    else
        printf '{"meta":{"source_image":"%s","collected_at":"%s","status":"%s","error":"%s"}}\n' \
            "$image" "$ts" "$status" "$errmsg"
    fi
}

export -f inspect_one
export INNER_SCRIPT_B64 TIMEOUT

# --------------------------------------------------------------------------
# 确定镜像列表
# --------------------------------------------------------------------------
declare -a IMAGES=()

if [[ -z "${ARG}" ]]; then
    # 模式1：扫描所有本地镜像
    log_info "未指定输入，扫描 docker images 中的所有本地镜像..."
    mapfile -t IMAGES < <(
        docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep -v '<none>' | sort -u
    )
    if [[ -n "$FILTER" ]]; then
        mapfile -t IMAGES < <(printf '%s\n' "${IMAGES[@]}" | grep -E "$FILTER" || true)
        log_info "过滤关键词 '$FILTER' 命中 ${#IMAGES[@]} 个"
    fi
    [[ ${#IMAGES[@]} -eq 0 ]] && { log_err "本地没有任何镜像"; exit 1; }
    : "${OUTPUT_DIR:=env_inspect_out}"

elif [[ -f "${ARG}" ]]; then
    # 模式2：从文件读取镜像列表（每行一个，# 开头跳过）
    log_info "从文件读取镜像列表: ${ARG}"
    while IFS= read -r line; do
        line="${line%%#*}"          # 去掉行内注释
        line="${line// /}"          # 去掉空格
        [[ -z "$line" ]] && continue
        IMAGES+=("$line")
    done < "${ARG}"
    [[ ${#IMAGES[@]} -eq 0 ]] && { log_err "文件中没有有效镜像名: ${ARG}"; exit 1; }
    : "${OUTPUT_DIR:=env_inspect_out}"

else
    # 模式3：单个镜像名
    if ! docker image inspect "${ARG}" &>/dev/null 2>&1; then
        log_err "镜像不存在: ${ARG}（如需从 tar 文件加载，暂请手动 docker load 后再运行）"
        exit 1
    fi
    IMAGES=("${ARG}")
    : "${OUTPUT_DIR:=env_inspect_out}"
fi

TOTAL=${#IMAGES[@]}
log_info "共 $TOTAL 个镜像, 并发度: ${MAX_PARALLEL}, 超时: ${TIMEOUT}s"

# --------------------------------------------------------------------------
# 创建输出目录结构
# --------------------------------------------------------------------------
IMAGES_SUBDIR="${OUTPUT_DIR}/images"
mkdir -p "$IMAGES_SUBDIR"
log_info "输出目录: $OUTPUT_DIR"
log_info "  汇总文件: ${OUTPUT_DIR}/summary.json"
log_info "  单镜像目录: ${IMAGES_SUBDIR}/"

# --------------------------------------------------------------------------
# 将镜像名转换为安全文件名（冒号、斜杠、空格替换为_）
# --------------------------------------------------------------------------
safe_filename() {
    printf '%s' "$1" | sed 's|[:/\\  ]|_|g'
}

# --------------------------------------------------------------------------
# 并发执行
# --------------------------------------------------------------------------
declare -a PIDS=() TMPFILES=()
ALL_RESULTS_FILE=$(mktemp)
trap 'rm -f "$_TMPSCRIPT" "$ALL_RESULTS_FILE"' EXIT

cleanup() {
    log_warn "中断，清理中..."
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
    for f in "${TMPFILES[@]:-}"; do rm -f "$f"; done
    rm -f "$ALL_RESULTS_FILE"
    exit 130
}
trap cleanup INT TERM

flush_head() {
    local head_tf="${TMPFILES[0]}"
    wait "${PIDS[0]}" 2>/dev/null || true
    PIDS=("${PIDS[@]:1}")
    TMPFILES=("${TMPFILES[@]:1}")
    if [[ -s "$head_tf" ]]; then
        local json_line
        json_line=$(cat "$head_tf")
        # 追加到汇总临时文件
        echo "$json_line" >> "$ALL_RESULTS_FILE"
        # 写单镜像文件
        local img_name
        img_name=$(echo "$json_line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('meta',{}).get('source_image','unknown'))" 2>/dev/null || echo "unknown")
        local safe_name
        safe_name=$(safe_filename "$img_name")
        echo "$json_line" | python3 -m json.tool > "${IMAGES_SUBDIR}/${safe_name}.json" 2>/dev/null \
            || echo "$json_line" > "${IMAGES_SUBDIR}/${safe_name}.json"
    fi
    rm -f "$head_tf"
}

for i in "${!IMAGES[@]}"; do
    img="${IMAGES[$i]}"
    tf=$(mktemp)
    TMPFILES+=("$tf")

    (
        log_info "[$(( i+1 ))/$TOTAL] $img"
        inspect_one "$img" "$i" "$TOTAL" > "$tf"
        log_ok  "[$(( i+1 ))/$TOTAL] done: $img"
    ) &
    PIDS+=($!)

    if (( ${#PIDS[@]} >= MAX_PARALLEL )); then
        flush_head
    fi
done

# 等待剩余
while (( ${#PIDS[@]} > 0 )); do
    flush_head
done

# --------------------------------------------------------------------------
# 生成汇总 summary.json（JSON Array 格式）
# --------------------------------------------------------------------------
SUMMARY_FILE="${OUTPUT_DIR}/summary.json"
python3 - "$ALL_RESULTS_FILE" "$SUMMARY_FILE" << 'PYEOF'
import sys, json
src = sys.argv[1]
dst = sys.argv[2]
records = []
with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception as e:
            records.append({"parse_error": str(e), "raw": line[:500]})
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(records, f, ensure_ascii=False, indent=2)
PYEOF

rm -f "$ALL_RESULTS_FILE"

# --------------------------------------------------------------------------
# 摘要统计
# --------------------------------------------------------------------------
total_singles=$(ls "${IMAGES_SUBDIR}"/*.json 2>/dev/null | wc -l | tr -d ' ')
log_ok "===== 采集完成 ====="
log_ok "  共处理镜像: $TOTAL 个"
log_ok "  单镜像文件: $total_singles 个 -> ${IMAGES_SUBDIR}/"
log_ok "  汇总文件:   $SUMMARY_FILE"

if command -v python3 &>/dev/null && [[ -f "$SUMMARY_FILE" ]]; then
    python3 << PYEOF2
import json, sys
from collections import Counter, defaultdict
try:
    with open('${SUMMARY_FILE}') as f:
        records = json.load(f)
    status_cnt = Counter()
    lang_detected = defaultdict(int)
    for r in records:
        status_cnt[r.get('meta', {}).get('status', '?')] += 1
        # 检测语言
        for lang, key in [('go','go'), ('python','python'), ('java','java'),
                           ('rust','rust'), ('nodejs','nodejs'), ('php','php'),
                           ('ruby','ruby'), ('.net','.net')]:
            ld = r.get(lang, r.get(key, {}))
            if isinstance(ld, dict):
                for v in ld.values():
                    if v and str(v).strip() and str(v) != 'installed':
                        lang_detected[lang] += 1
                        break
    print()
    print('  状态统计:', dict(status_cnt))
    print('  检测到语言环境:', dict(lang_detected))
    print()
except Exception as e:
    print('  统计失败:', e)
PYEOF2
fi
