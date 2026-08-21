#!/bin/bash
# common.sh — 中间件迁移公共库（被各 migrate_*.sh 与 run_migration.sh source）
# 提供：部署目录推导、依赖管理（JDK 版本统一策略）、冲突处理（目录/服务）、
#       服务启停与注册、状态幂等、日志、JSON/registry 查询等通用函数。

# ==================== 环境初始化 ====================
load_env() {
    [ -f "${WORK_DIR:-}/.env" ] && source "$WORK_DIR/.env"
    SKILL_DIR="${SKILL_DIR:-$(
        _s="${BASH_SOURCE[0]}"
        case "$_s" in /*) : ;; *) _s="$PWD/$_s" ;; esac
        _s="$(readlink -f "$_s" 2>/dev/null || printf '%s' "$_s")"
        cd "$(dirname "$_s")/../.." && pwd
    )}"
    WORK_DIR="${WORK_DIR:-$SKILL_DIR/_runtime}"
    REPORTS_DIR="${REPORTS_DIR:-$WORK_DIR/reports}"
    DOWNLOADS_DIR="${DOWNLOADS_DIR:-$WORK_DIR/downloads}"
    STATE_DIR="${STATE_DIR:-$SKILL_DIR/_runtime/state}"
    REFERENCE_DIR="${REFERENCE_DIR:-$SKILL_DIR/reference}"
    REGISTRY_FILE="${REGISTRY_FILE:-$SKILL_DIR/config/middleware_registry.json}"
    mkdir -p "$WORK_DIR" "$REPORTS_DIR" "$DOWNLOADS_DIR" "$STATE_DIR"
    PERMISSION_MODE="${PERMISSION_MODE:-strict}"
    export SKILL_DIR WORK_DIR REPORTS_DIR DOWNLOADS_DIR STATE_DIR REFERENCE_DIR REGISTRY_FILE PERMISSION_MODE

    local missing=()
    for cmd in python3; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
    [ ${#missing[@]} -gt 0 ] && { log_error "缺少必要命令: ${missing[*]}"; return 1; }
    return 0
}

require_env() {
    local missing=()
    for var in "$@"; do [ -z "${!var:-}" ] && missing+=("$var"); done
    [ ${#missing[@]} -gt 0 ] && { echo "ERROR: 缺少必要环境变量: ${missing[*]}" >&2; return 1; }
    return 0
}

# ==================== JSON 查询（基于 python3，替代 jq）====================
# 表达式中用 d 代表根数据
json_query() { python3 "$SKILL_DIR/scripts/lib/json_query.py" "$@"; }

# ==================== Registry 读取（基于 python3，替代 yq）====================
# 用法: registry_get '<yq_path>' [default]; 支持 .a.b.c / .a."b".c / .a[0].b / .a.b | length
registry_get() {
    [ ! -f "$REGISTRY_FILE" ] && { echo "${2:-}"; return 0; }
    local value
    value=$(python3 "$SKILL_DIR/scripts/lib/registry_query.py" "$1" "$REGISTRY_FILE" 2>/dev/null)
    if [ "$value" = "null" ] || [ -z "$value" ]; then echo "${2:-}"; else echo "$value"; fi
}

registry_has() {
    [ -f "$REGISTRY_FILE" ] || return 1
    python3 "$SKILL_DIR/scripts/lib/registry_query.py" -e "$1" "$REGISTRY_FILE" 2>/dev/null
}

normalize_middleware_type() {
    case "$1" in
        es) echo "elasticsearch" ;;
        rabbitmq-server) echo "rabbitmq" ;;
        *) echo "$1" ;;
    esac
}

# ==================== 版本与路径解析 ====================
resolve_service_name() {
    [ -n "${SERVICE_NAME:-}" ] && { echo "$SERVICE_NAME"; return 0; }
    local svc; svc=$(registry_get ".strategies.\"$1\".service_name")
    [ -n "$svc" ] && echo "$svc" || echo "$1"
}

resolve_arm_service() {
    local svc_name; svc_name=$(resolve_service_name "$1")
    [ "$(registry_get ".strategies.\"$1\".service_name_suffix" "false")" = "true" ] \
        && echo "${svc_name}-arm" || echo "$svc_name"
}

resolve_install_dir() {
    [ -n "${INSTALL_DIR:-}" ] && { echo "$INSTALL_DIR"; return 0; }
    registry_get ".strategies.\"$1\".install_dir" "/opt/$1"
}

resolve_config_dir() {
    [ -n "${CONFIG_DIR:-}" ] && { echo "$CONFIG_DIR"; return 0; }
    registry_get ".strategies.\"$1\".config_dir" ""
}

resolve_download_url() {
    [ -z "${DOWNLOAD_URL:-}" ] && return 0
    echo "${DOWNLOAD_URL//\$\{TARGET_VERSION\}/${TARGET_VERSION:-}}"
}

resolve_local_package_path() { echo "${LOCAL_PACKAGE_PATH:-}"; }

resolve_package_file_name() {
    [ -n "${PACKAGE_FILE_NAME:-}" ] && { echo "$PACKAGE_FILE_NAME"; return 0; }
    local url; url=$(resolve_download_url)
    [ -n "$url" ] && basename "$url" || echo ""
}

resolve_artifact_paths() {
    [ -n "${CONFIG_PATHS:-}" ] || return 0
    printf '%s' "$CONFIG_PATHS" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for x in data: print(x)
except: pass
" 2>/dev/null
}

resolve_artifact_file() {
    local artifact="$1" base
    [ -n "$artifact" ] || return 1
    case "$artifact" in
        /*) printf '%s\n' "$artifact" ;;
        *)
            base="${ARTIFACT_BASE_DIR:-${SOURCE_DIR:-}}"
            [ -n "$base" ] || return 1
            printf '%s/%s\n' "${base%/}" "$artifact"
            ;;
    esac
}

# ==================== 目标部署目录推导 ====================
# plan 无 target.deploy_dir 字段，部署目录由产品策略(registry deploy_dir_strategy：source_parent 默认 / install_dir / skip)和源端信息(source.location)推导
# 优先级：DEPLOY_DIR_<TYPE>(env 显式指定, "skip"=跳过) > 产品策略+源端信息推导 > /opt/<type>-<version> 默认目录
# 返回码：0=成功 1=硬失败 4=用户跳过；失败设置 DERIVE_ERROR
DERIVE_ERROR=""
derive_deploy_dir() {
    local mtype="$1" source_dir="$2" target_version="$3"
    DERIVE_ERROR=""

    if [ -n "$mtype" ]; then
        local upper var user_val
        upper=$(echo "$mtype" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        eval "user_val=\${DEPLOY_DIR_${upper}:-}"
        if [ -n "$user_val" ]; then
            [ "$user_val" = "skip" ] && { DERIVE_ERROR="$mtype: 用户选择跳过"; return 4; }
            echo "$user_val"; return 0
        fi
    fi

    local strategy
    if registry_has ".strategies.\"$mtype\""; then
        strategy=$(registry_get ".strategies.\"$mtype\".deploy_dir_strategy" "source_parent")
    else
        # 未登记产品优先沿用源目录；源目录缺失时使用确定性的 /opt 默认目录。
        if [ -z "$source_dir" ]; then
            [ -z "$target_version" ] && { DERIVE_ERROR="$mtype: target_version 为空"; log_error "$DERIVE_ERROR"; return 1; }
            echo "/opt/${mtype}-${target_version}"
            return 0
        fi
        strategy="source_parent"
    fi
    case "$strategy" in
        skip) echo ""; return 0 ;;
        install_dir)
            # 优先使用 source.location 推导部署目录；source.location 缺失时才回退 registry 的 install_dir
            if [ -n "$source_dir" ]; then
                [ -z "$target_version" ] && { DERIVE_ERROR="$mtype: target_version 为空"; log_error "$DERIVE_ERROR"; return 1; }
                local root="${source_dir%/}"
                case "$root" in */conf|*/config) root="$(dirname "$root")" ;; esac
                # 防御 root 为空或为 /，避免生成 //xxx 或 ./xxx 等异常路径
                case "$root" in
                    ""|"/") DERIVE_ERROR="$mtype: 无法从 source.location 推导部署目录: $source_dir"; log_error "$DERIVE_ERROR"; return 1 ;;
                esac
                echo "$(dirname "$root")/${mtype}-${target_version}"
                return 0
            fi
            local reg_dir
            reg_dir=$(registry_get ".strategies.\"$mtype\".install_dir" "")
            if [ -n "$reg_dir" ]; then
                echo "$reg_dir"
                return 0
            fi
            DERIVE_ERROR="$mtype: source.location 为空且未配置 install_dir"
            log_error "$DERIVE_ERROR"
            return 1
            ;;
        source_parent|*)
            [ -z "$source_dir" ] && { DERIVE_ERROR="$mtype: source.location 为空"; log_error "$DERIVE_ERROR"; return 1; }
            [ -z "$target_version" ] && { DERIVE_ERROR="$mtype: target_version 为空"; log_error "$DERIVE_ERROR"; return 1; }
            echo "$(dirname "$(dirname "$source_dir")")/${mtype}-${target_version}"
            ;;
    esac
}

# 返回非交互模式下当前中间件的显式冲突决策；优先级：ID > 类型 > 全局。
resolve_conflict_action() {
    local mtype="${1:-}" mid="${2:-}" action="${CONFLICT_ACTION:-}"
    local upper per_value
    if [ -n "$mtype" ]; then
        upper=$(printf '%s' "$mtype" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')
        eval "per_value=\${CONFLICT_ACTION_${upper}:-}"
        [ -n "$per_value" ] && action="$per_value"
    fi
    if [ -n "$mid" ]; then
        upper=$(printf '%s' "$mid" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')
        eval "per_value=\${CONFLICT_ACTION_${upper}:-}"
        [ -n "$per_value" ] && action="$per_value"
    fi
    echo "$action"
}

# 部署目录已存在时的交互处理
# 返回码：0=继续(目录不存在或已删除) 1=跳过 2=非交互且未设置 CONFLICT_ACTION
# auto 模式自动跳过；非 tty 按 ID > 类型 > 全局的 CONFLICT_ACTION 决策
prompt_deploy_dir_conflict() {
    local deploy_dir="$1" mtype="${2:-}" mid="${3:-}"

    [ ! -d "$deploy_dir" ] && return 0

    [ "${PERMISSION_MODE:-strict}" = "auto" ] && {
        log_warn "目标部署目录已存在(auto 模式自动跳过): $deploy_dir"; return 1
    }

    if [ ! -t 0 ]; then
        local action
        action=$(resolve_conflict_action "$mtype" "$mid")
        case "$action" in
            overwrite)
                log_warn "非交互模式：覆盖 $deploy_dir${mtype:+ ($mtype)}"
                ls -la "$deploy_dir" 2>/dev/null
                rm -rf "$deploy_dir" || { log_error "删除失败: $deploy_dir"; return 1; }
                log_info "已删除现有目录，继续覆盖安装"; return 0
                ;;
            skip)
                log_warn "非交互模式：跳过 $deploy_dir${mtype:+ ($mtype)}"; return 1
                ;;
            *)
                log_error "非交互环境且目录已存在: $deploy_dir"
                if [ -n "$mtype" ]; then
                    local upper; upper=$(echo "$mtype" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                    log_error "请设置 CONFLICT_ACTION_${upper}=overwrite|skip，或 CONFLICT_ACTION=overwrite|skip 后重新执行"
                else
                    log_error "请设置 CONFLICT_ACTION=overwrite|skip 后重新执行"
                fi
                return 2
                ;;
        esac
    fi

    log_warn "目标部署目录已存在: $deploy_dir"
    local choice
    while true; do
        read -r -p "检测到目标环境已存在该软件，请选择操作 [1=覆盖, 2=跳过（默认）]: " choice
        case "$choice" in
            1)
                log_warn "覆盖将删除以下内容："
                ls -la "$deploy_dir" 2>/dev/null; echo "----"
                local confirm
                read -r -p "确认删除 '$deploy_dir' 并覆盖安装？[y/N]: " confirm
                case "$confirm" in
                    y|Y)
                        rm -rf "$deploy_dir" || { log_error "删除失败: $deploy_dir"; return 1; }
                        log_info "已删除现有目录，继续覆盖安装"; return 0
                        ;;
                    *) log_info "已取消覆盖，请重新选择" ;;
                esac
                ;;
            ""|2) log_info "用户选择跳过该中间件迁移"; return 1 ;;
            *) log_warn "无效选择: $choice，请输入 1 或 2" ;;
        esac
    done
}

# 备份 systemd service 文件（不删除原服务目录和配置）
_backup_service_file() {
    local arm_svc="$1" svc_file backup
    for svc_file in "/etc/systemd/system/${arm_svc}.service" "/usr/lib/systemd/system/${arm_svc}.service"; do
        if [ -f "$svc_file" ]; then
            backup="${svc_file}.bak.$(date +%Y%m%d%H%M%S)"
            cp "$svc_file" "$backup" && log_info "已备份: $svc_file -> $backup"
        fi
    done
}

# 目标环境已存在同名 systemd 服务时的处理
# 返回码：0=继续(无冲突或用户选择继续) 1=跳过 2=非交互待确认
# 不删除原来的服务目录和配置文件，仅备份 service 文件后覆盖注册
prompt_service_conflict() {
    local arm_svc="$1" mtype="${2:-}" mid="${3:-}"

    # 服务不存在 → 无冲突
    systemctl cat "$arm_svc" >/dev/null 2>&1 || return 0

    [ "${PERMISSION_MODE:-strict}" = "auto" ] && {
        log_warn "目标环境已存在同名服务(auto 模式自动跳过): $arm_svc"; return 1
    }

    if [ ! -t 0 ]; then
        local action
        action=$(resolve_conflict_action "$mtype" "$mid")
        case "$action" in
            overwrite)
                log_warn "非交互模式：备份并覆盖服务注册: $arm_svc"
                _backup_service_file "$arm_svc"
                return 0
                ;;
            skip)
                log_warn "非交互模式：跳过 $arm_svc${mtype:+ ($mtype)}"; return 1
                ;;
            *)
                log_error "非交互环境且服务已存在: $arm_svc"
                if [ -n "$mtype" ]; then
                    local upper; upper=$(echo "$mtype" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                    log_error "请设置 CONFLICT_ACTION_${upper}=overwrite|skip，或 CONFLICT_ACTION=overwrite|skip 后重新执行"
                else
                    log_error "请设置 CONFLICT_ACTION=overwrite|skip 后重新执行"
                fi
                return 2
                ;;
        esac
    fi

    log_warn "目标环境已存在同名服务: $arm_svc"
    local choice
    while true; do
        read -r -p "检测到目标环境已有服务 [$arm_svc]，选择操作 [1=备份后覆盖服务注册(不删原目录和配置), 2=跳过（默认）]: " choice
        case "$choice" in
            1)
                _backup_service_file "$arm_svc"
                log_info "将覆盖服务注册，原有服务目录和配置文件不受影响"; return 0
                ;;
            ""|2) log_info "用户选择跳过该中间件迁移"; return 1 ;;
            *) log_warn "无效选择: $choice，请输入 1 或 2" ;;
        esac
    done
}

# ==================== 状态与幂等性 ====================
_migration_state_key() {
    local key="$1"
    if [ -n "${MIDDLEWARE_STATE_KEY:-}" ] && [ "$key" = "${MIDDLEWARE_TYPE:-}" ]; then
        key="$MIDDLEWARE_STATE_KEY"
    fi
    printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_'
}

get_migration_state() {
    local key file
    key=$(_migration_state_key "$1")
    file="$STATE_DIR/${key}.status"
    [ -f "$file" ] && cat "$file" || echo "pending"
}

set_migration_state() {
    local requested="$1" state="$2" key type_key
    key=$(_migration_state_key "$requested")
    echo "$state" > "$STATE_DIR/${key}.status"

    # 主迁移项按 route id 保存，同时保留 type 状态供依赖判断复用，避免 JDK 等依赖重复安装。
    if [ -n "${MIDDLEWARE_STATE_KEY:-}" ] && [ "$requested" = "${MIDDLEWARE_TYPE:-}" ]; then
        type_key=$(printf '%s' "$MIDDLEWARE_TYPE" | tr -c 'A-Za-z0-9._-' '_')
        [ "$type_key" = "$key" ] || echo "$state" > "$STATE_DIR/${type_key}.status"
    fi
}

# ==================== JAVA_HOME 解析 ====================
# Java 中间件脚本统一使用该函数解析 JAVA_HOME，避免各脚本逻辑重复。
# 解析顺序：1) 环境变量 JAVA_HOME（bin/java 可执行时） 2) 标准运行时入口 /usr/lib/jvm/java-arm（migrate_jdk.sh 创建）
#          3) /opt 下 JDK 目录兜底。全部不可用返回 1（脚本据此报"请先完成 JDK 迁移"）。
resolve_java_home() {
    local java_home="${JAVA_HOME:-}"
    if [ -n "$java_home" ] && [ -x "$java_home/bin/java" ]; then
        echo "$java_home"; return 0
    fi
    if [ -x "/usr/lib/jvm/java-arm/bin/java" ]; then
        echo "/usr/lib/jvm/java-arm"; return 0
    fi
    local candidate
    candidate=$(ls -d /opt/jdk-* /opt/*jdk* 2>/dev/null | head -1)
    if [ -n "$candidate" ] && [ -x "$candidate/bin/java" ]; then
        echo "$candidate"; return 0
    fi
    return 1
}

# 提取版本字符串的主版本号（支持 8 / 11 / 1.8.0 / 8u372 等），无法识别时输出空
major_version() {
    printf '%s' "$1" | python3 -c "import sys,re;s=sys.stdin.read().strip();m=re.match(r'1\.(\d+)',s);print(m.group(1) if m else (re.match(r'\d+',s).group() if re.match(r'\d+',s) else ''))"
}

# 判断已解析的 Java 运行时主版本是否满足依赖声明的目标版本（支持 8/11/1.8.0 等写法）
java_version_ok() {
    local home="$1" want="$2"
    [ -n "$home" ] && [ -x "$home/bin/java" ] || return 1
    [ -z "$want" ] && return 0
    local want_m cur_m
    want_m=$(major_version "$want")
    cur_m=$("$home/bin/java" -version 2>&1 | head -1 | python3 -c "import sys,re;s=sys.stdin.read();m=re.search(r'(\d+(?:\.\d+){0,2})',s);v=m.group(1) if m else '';print(re.match(r'1\.(\d+)',v).group(1) if re.match(r'1\.(\d+)',v) else (re.match(r'\d+',v).group() if re.match(r'\d+',v) else ''))")
    [ -n "$cur_m" ] && [ "$cur_m" = "$want_m" ]
}

# 统计 plan 中所有 Java 中间件（含依赖）所需的 JDK 主版本，输出空格分隔的去重列表，如 "8 11"。
# 用于判定"计划内所有中间件兼容的统一 JDK 版本"：全部一致时由调用方统一使用，避免顾左失右。
plan_java_versions() {
    [ -n "${MIDDLEWARE_LIST:-}" ] || return 0
    printf '%s' "$MIDDLEWARE_LIST" | REGISTRY_FILE="$REGISTRY_FILE" python3 -c "
import json, os, sys, re
items = json.load(sys.stdin)
reg = {}
rp = os.environ.get('REGISTRY_FILE', '')
if rp and os.path.exists(rp):
    with open(rp, encoding='utf-8-sig') as f:
        reg = json.load(f)
def major(v):
    s = str(v or '')
    m = re.match(r'1\.(\d+)', s)
    if m:
        return m.group(1)
    m = re.match(r'(\d+)', s)
    return m.group(1) if m else ''
strategies = reg.get('strategies', {}) or {}
out = []
for it in items:
    strat = strategies.get(it.get('type') or '')
    if not strat:
        continue
    for dep in strat.get('dependencies', []) or []:
        if dep.get('type') in ('openjdk', 'ibmjdk', 'oraclejdk', 'bisenjre', 'jdk'):
            v = major(dep.get('target_version'))
            if v:
                out.append(v)
print(' '.join(sorted(set(out), key=lambda x: int(x))))
" 2>/dev/null
}

# 按依赖声明的目标版本解析对应 JDK（支持 8/11/1.8.0 等写法），替代各脚本硬编码版本查找。
# 搜索顺序：JAVA_HOME -> /usr/lib/jvm/java-arm -> /usr/lib/jvm/java-<major>* -> /opt 下迁移安装的 JDK
resolve_java_home_for_version() {
    local want="$1"
    local c
    if [ -n "${JAVA_HOME:-}" ] && java_version_ok "$JAVA_HOME" "$want"; then
        echo "$JAVA_HOME"; return 0
    fi
    if java_version_ok "/usr/lib/jvm/java-arm" "$want"; then
        echo "/usr/lib/jvm/java-arm"; return 0
    fi
    for c in /usr/lib/jvm/java-1.8.0 /usr/lib/jvm/java-1.8.0-openjdk /usr/lib/jvm/java-8-openjdk* /usr/lib/jvm/java-11* /usr/lib/jvm/java-17* /usr/lib/jvm/java-1.* /usr/lib/jvm/java-*; do
        [ -x "$c/bin/java" ] || continue
        if java_version_ok "$c" "$want"; then
            echo "$c"; return 0
        fi
    done
    for c in /opt/bisheng-jdk-* /opt/jdk-* /opt/java-* /opt/*jdk*; do
        [ -x "$c/bin/java" ] || continue
        if java_version_ok "$c" "$want"; then
            echo "$c"; return 0
        fi
    done
    return 1
}

# ==================== 依赖管理 ====================
detect_current_version() {
    case "$1" in
        openjdk|ibmjdk|oraclejdk)
            local v
            v=$(java -version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
            [ -z "$v" ] && v=$(java -version 2>&1 | head -1 | grep -oE 'version "[0-9]+"' | grep -oE '[0-9]+' | head -1)
            echo "$v"
            ;;
        *) echo "" ;;
    esac
}

# 确保中间件依赖就绪；未就绪则自动迁移（如 Java 中间件依赖 JDK）
# 返回 0=全部就绪 1=有依赖失败
ensure_dependencies() {
    local mtype="$1"
    local dep_count; dep_count=$(registry_get ".strategies.\"$mtype\".dependencies | length" "0")
    [ "$dep_count" = "0" ] || [ "$dep_count" = "null" ] && return 0

    local i dep_type dep_target dep_current dep_script dep_install_method
    for ((i=0; i<dep_count; i++)); do
        dep_type=$(registry_get ".strategies.\"$mtype\".dependencies[$i].type")
        [ -z "$dep_type" ] && continue
        dep_type=$(normalize_middleware_type "$dep_type")
        dep_target=$(registry_get ".strategies.\"$mtype\".dependencies[$i].target_version")
        # 计划内所有 Java 中间件的 JDK 需求一致时统一使用该版本，避免按各自版本解析导致顾左失右。
        [ -n "${UNIFIED_JDK_VERSION:-}" ] && dep_target="$UNIFIED_JDK_VERSION"

        case "$(get_migration_state "$dep_type")" in
            success|success_with_warnings)
                # Java 依赖额外校验主版本匹配，避免"已迁移 JDK11"错误满足 BES 等对 JDK8 的依赖
                case "$dep_type" in
                    openjdk|ibmjdk|oraclejdk|bisenjre|jdk)
                        if [ -n "$dep_target" ]; then
                            if existing_java_home=$(resolve_java_home) && java_version_ok "$existing_java_home" "$dep_target"; then
                                export JAVA_HOME="$existing_java_home"
                                log_info "[DEP] 依赖 $dep_type 已就绪且版本匹配(需 $dep_target)，跳过"
                                continue
                            fi
                            log_warn "[DEP] 依赖 $dep_type 已就绪但版本不匹配(需 $dep_target)，继续解析/安装"
                        else
                            log_info "[DEP] 依赖 $dep_type 已就绪，跳过"
                            continue
                        fi
                        ;;
                    *)
                        log_info "[DEP] 依赖 $dep_type 已就绪，跳过"
                        continue
                        ;;
                esac
                ;;
        esac

        # Java 依赖优先复用目标环境中版本匹配的标准运行时入口。
        case "$dep_type" in
            openjdk|ibmjdk|oraclejdk|bisenjre|jdk)
                local existing_java_home
                if existing_java_home=$(resolve_java_home) && java_version_ok "$existing_java_home" "$dep_target"; then
                    export JAVA_HOME="$existing_java_home"
                    set_migration_state "$dep_type" success
                    log_info "[DEP] 复用已就绪 Java 运行时: $JAVA_HOME"
                    continue
                fi
                ;;
        esac

        dep_script=$(registry_get ".strategies.\"$dep_type\".script")
        dep_install_method=$(registry_get ".strategies.\"$dep_type\".install_method")

        [ -z "$dep_script" ] && { log_error "[DEP] 依赖 $dep_type 未配置迁移脚本"; return 1; }

        dep_current=$(detect_current_version "$dep_type")
        [ -z "$dep_current" ] && dep_current="unknown"

        log_info "[DEP] 自动安装依赖 $dep_type ($dep_current -> ${dep_target:-auto})"

        local dep_rc=0
        (
            export MIDDLEWARE_TYPE="$dep_type" CURRENT_VERSION="$dep_current" TARGET_VERSION="$dep_target"
            export SOURCE_DIR="" INSTALL_METHOD="$dep_install_method" MIGRATION_PATH="REGISTERED"
            unset MIDDLEWARE_STATE_KEY
            # 依赖来自 registry 而非 plan，无独立的 source_type；
            # 显式清空，避免父中间件（run_migration.sh 已 export）的 SOURCE_TYPE 泄漏影响依赖安装
            export SOURCE_TYPE=""
            case "$dep_type" in
                openjdk|ibmjdk|oraclejdk)
                    # 从 plan 的 middleware 项中按依赖目标版本选择对应 JDK 包，
                    # 避免存在多个 JDK 项时固定取第一个（如取到 8 却要装 11）。
                    # 无匹配版本时输出 JDK_MISMATCH 交给 bash 侧提示，不静默取错版本。
                    if [ -n "${MIDDLEWARE_LIST:-}" ]; then
                        local jdk_pick
                        jdk_pick=$(printf '%s' "$MIDDLEWARE_LIST" | python3 -c "
import json, sys, re, shlex
items = json.load(sys.stdin)
want = sys.argv[1]
def major(v):
    s = str(v or '')
    m = re.match(r'1\.(\d+)', s)
    if m:
        return int(m.group(1))
    m = re.match(r'(\d+)', s)
    return int(m.group(1)) if m else -1
want_m = major(want)
cands = [it for it in items if it.get('type') == 'openjdk']
pick = next((it for it in cands if major(it.get('target_version')) == want_m), None)
if pick is not None:
    print('JDK_URL=' + shlex.quote(pick.get('download_url') or ''))
    print('JDK_LOCAL=' + shlex.quote(pick.get('local_package_path') or ''))
    print('JDK_FILE=' + shlex.quote(pick.get('package_file_name') or ''))
    print('JDK_VER=' + shlex.quote(pick.get('target_version') or ''))
elif cands:
    print('JDK_MISMATCH=1')
    print('JDK_CAND_VERS=' + shlex.quote(','.join((it.get('target_version') or 'unknown') for it in cands)))
" "$dep_target" 2>/dev/null)
                        if [ -n "$jdk_pick" ]; then
                            local JDK_URL JDK_LOCAL JDK_FILE JDK_VER JDK_MISMATCH JDK_CAND_VERS
                            eval "$jdk_pick"
                            if [ -n "$JDK_MISMATCH" ]; then
                                log_warn "[DEP] plan 内 JDK 包版本(${JDK_CAND_VERS:-未知}) 不满足依赖需求(需 JDK $dep_target)，请补充对应版本 JDK 包"
                            else
                                [ -n "$JDK_URL" ] && export DOWNLOAD_URL="$JDK_URL"
                                [ -n "$JDK_LOCAL" ] && export LOCAL_PACKAGE_PATH="$JDK_LOCAL"
                                [ -n "$JDK_FILE" ] && export PACKAGE_FILE_NAME="$JDK_FILE"
                                [ -n "$JDK_VER" ] && export TARGET_VERSION="$JDK_VER"
                            fi
                            unset JDK_URL JDK_LOCAL JDK_FILE JDK_VER JDK_MISMATCH JDK_CAND_VERS
                        fi
                    fi
                    # 未在 middleware 中找到匹配 JDK 项时回退到全局 JAVA_RUNTIME_*（仅当版本匹配，避免取错版本）
                    if [ -z "${DOWNLOAD_URL:-}" ] && [ -n "${JAVA_RUNTIME_URL:-}" ]; then
                        if [ -z "${JAVA_RUNTIME_VERSION:-}" ] || [ "$(major_version "$JAVA_RUNTIME_VERSION")" = "$(major_version "$dep_target")" ]; then
                            export DOWNLOAD_URL="$JAVA_RUNTIME_URL"
                            [ -n "${JAVA_RUNTIME_LOCAL_PATH:-}" ] && export LOCAL_PACKAGE_PATH="$JAVA_RUNTIME_LOCAL_PATH"
                            [ -n "${JAVA_RUNTIME_FILE_NAME:-}" ] && export PACKAGE_FILE_NAME="$JAVA_RUNTIME_FILE_NAME"
                            [ -n "${JAVA_RUNTIME_VERSION:-}" ] && export TARGET_VERSION="$JAVA_RUNTIME_VERSION"
                        else
                            log_warn "[DEP] 全局 JAVA_RUNTIME_VERSION($JAVA_RUNTIME_VERSION) 与依赖需求(JDK $dep_target)不匹配，忽略"
                        fi
                    fi
                    ;;
            esac
            set +e; bash "$SKILL_DIR/$dep_script"; exit $?
        ) || dep_rc=$?

        [ "$dep_rc" -ne 0 ] && { log_error "[DEP] 依赖 $dep_type 安装失败"; return 1; }

        case "$dep_type" in
            openjdk|ibmjdk|oraclejdk)
                # 指向实际安装的、版本匹配的 JDK，避免 /usr/lib/jvm/java-arm 链接被后续安装覆盖指向错误版本
                if installed_home=$(resolve_java_home_for_version "$dep_target"); then
                    export JAVA_HOME="$installed_home"
                fi
                ;;
        esac
        log_info "[DEP] 依赖 $dep_type 安装完成"
    done
    return 0
}

# ==================== 日志（输出到 stderr）====================
log_info()  { echo "[INFO] $*" >&2; }
log_warn()  { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_step()  { echo "[STEP] $*" >&2; }

log_reference() {
    local mtype="$1" ref_dir="${REFERENCE_DIR:-$SKILL_DIR/reference}"
    log_info "知识库参考："
    [ -f "$ref_dir/middleware_issues.md" ] && log_info "  - $ref_dir/middleware_issues.md"
    if [ -f "$ref_dir/middleware_issues.md" ] && [ -n "$mtype" ]; then
        local match; match=$(grep -in "^### .*\b$mtype\b" "$ref_dir/middleware_issues.md" | head -1)
        [ -n "$match" ] && log_info "  相关段落: $ref_dir/middleware_issues.md 第 $(echo "$match" | cut -d: -f1) 行"
    fi
}

# ==================== 下载与缓存 ====================
download_package() {
    local url="$1" output_path="$DOWNLOADS_DIR/$2"
    if [ -f "$output_path" ] && [ -s "$output_path" ]; then
        log_info "使用已缓存的下载包: $output_path"; echo "$output_path"; return 0
    fi
    log_info "下载: $url"
    # --connect-timeout 防连接挂起，--max-time 防大文件/慢网络响应悬挂
    curl -sfL --connect-timeout 10 --max-time 600 "$url" -o "$output_path" || { log_error "下载失败: $url"; return 1; }
    [ -s "$output_path" ] || { log_error "下载文件为空: $url"; rm -f "$output_path"; return 1; }
    echo "$output_path"
}

# ==================== 服务管理 ====================
install_systemd_service() {
    local mtype="$1" arm_svc="$2" exec_start="$3" exec_stop="${4:-}" env_vars="${5:-}" service_type="${6:-simple}"
    local service_file="/etc/systemd/system/${arm_svc}.service"

    [ -f "/usr/lib/systemd/system/$(resolve_service_name "$mtype").service" ] && \
        cp "/usr/lib/systemd/system/$(resolve_service_name "$mtype").service" "$service_file"

    {
        echo "[Unit]"; echo "Description=${mtype} ARM Migration Service"; echo "After=network.target"; echo
        echo "[Service]"; echo "Type=$service_type"
        [ -n "$env_vars" ] && echo "Environment=$env_vars"
        echo "ExecStart=$exec_start"
        [ -n "$exec_stop" ] && echo "ExecStop=$exec_stop"
        echo "Restart=on-failure"; echo
        echo "[Install]"; echo "WantedBy=multi-user.target"
    } > "$service_file"

    systemctl daemon-reload
    systemctl enable "$arm_svc" 2>/dev/null || true
}

start_service() {
    local arm_svc="$1"
    log_step "启动服务: $arm_svc"
    systemctl start "$arm_svc" 2>/dev/null && { sleep 2; return 0; }
    log_error "服务启动失败: $arm_svc"
    systemctl status "$arm_svc" --no-pager 2>/dev/null || true
    return 1
}

stop_service() {
    local arm_svc="$1"
    systemctl stop "$arm_svc" 2>/dev/null || true
    systemctl disable "$arm_svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${arm_svc}.service"
    systemctl daemon-reload 2>/dev/null || true
}

stop_current_service() {
    log_step "停止当前服务: $1"
    stop_service "$2"
}

# ==================== 验证 ====================
run_validation() {
    local mtype="$1" arm_svc; arm_svc=$(resolve_arm_service "$mtype")
    log_step "执行迁移验证: $mtype"
    local all_passed=true section cmd count i

    for section in config service functional; do
        count=$(registry_get ".strategies.\"$mtype\".validation.${section} | length" "0")
        [ "$count" = "0" ] && continue
        for ((i=0; i<count; i++)); do
            cmd=$(registry_get ".strategies.\"$mtype\".validation.${section}[$i].command")
            [ -z "$cmd" ] && continue
            log_info "验证 [$section]: $cmd"
            if bash -c "$cmd" >/dev/null 2>&1; then
                log_info "验证通过 [$section]: $cmd"
            else
                log_error "验证失败 [$section]: $cmd"; all_passed=false
            fi
        done
    done

    [ "$all_passed" = "true" ]
}

# ==================== 报告 ====================
write_report() {
    local mtype="$1" extra="${2:-}" arm_svc
    arm_svc=$(resolve_arm_service "$mtype")
    {
        echo "# $mtype 迁移报告"; echo
        echo "## 迁移信息"
        echo "- 迁移类型: $mtype"
        echo "- 原版本: ${CURRENT_VERSION:-未提供}"
        echo "- 目标版本: ${TARGET_VERSION:-未提供}"
        echo "- 目标主机: $(hostname)"
        echo "- 源配置目录: ${SOURCE_DIR:-未提供}"
        echo "- 迁移时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- 运行ID: ${RUN_ID:-}"
        echo "- 服务名: $arm_svc"; echo
        echo "## 验证结果"
        echo "- 服务状态: $(systemctl is-active "$arm_svc" 2>/dev/null || echo 'unknown')"
        echo "- 架构: $(uname -m)"
        [ -n "$extra" ] && echo "$extra"
    } > "$REPORTS_DIR/${mtype}_migration_report.md"
}

# ==================== 通用迁移辅助 ====================
generic_install_artifact() {
    local mtype="$1" pkg_file local_path install_dir
    [ -z "${DEPLOY_DIR:-}" ] && { log_error "DEPLOY_DIR 未设置"; return 1; }
    install_dir="$DEPLOY_DIR"

    pkg_file=$(resolve_package_file_name)
    [ -z "$pkg_file" ] && pkg_file="package.tar.gz"

    local_path=$(resolve_local_package_path)
    if [ -n "$local_path" ] && [ -f "$local_path" ]; then
        log_info "使用本地安装包: $local_path"
        cp "$local_path" "$DOWNLOADS_DIR/$pkg_file" || { log_error "本地包复制失败"; return 1; }
    elif [ -n "$DOWNLOAD_URL" ]; then
        download_package "$DOWNLOAD_URL" "$pkg_file" >/dev/null || { log_error "下载失败: $DOWNLOAD_URL"; return 1; }
    else
        log_error "无可用包源（local_path/download_url 均缺失）"; return 1
    fi

    mkdir -p "$install_dir" || { log_error "创建安装目录失败: $install_dir"; return 1; }
    local package_path="$DOWNLOADS_DIR/$pkg_file"
    if ! install_binary_package "$package_path" "$install_dir"; then
        log_error "无法部署安装包: $package_path"
        return 1
    fi
    log_info "安装完成: $install_dir"
}

generic_restore_config() {
    local mtype="$1" install_dir artifacts
    [ -z "${DEPLOY_DIR:-}" ] && { log_error "DEPLOY_DIR 未设置"; return 1; }
    install_dir="$DEPLOY_DIR"

    [ -z "$SOURCE_DIR" ] && { log_info "无 source_dir，跳过配置恢复"; return 0; }
    [ ! -d "$SOURCE_DIR" ] && { log_warn "source_dir 不存在: $SOURCE_DIR"; return 0; }

    artifacts=$(resolve_artifact_paths)
    if [ -n "$artifacts" ]; then
        log_info "按 artifact_paths 精确恢复配置 -> $install_dir"
        local f dest_dir
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            dest_dir="$install_dir/$(dirname "$f")"
            mkdir -p "$dest_dir" 2>/dev/null || true
            cp -rn "$SOURCE_DIR/$f" "$dest_dir/" 2>/dev/null || log_warn "配置复制失败: $f"
        done <<< "$artifacts"
    else
        log_info "全量复制配置: $SOURCE_DIR -> $install_dir"
        cp -rn "$SOURCE_DIR"/* "$install_dir/" 2>/dev/null || true
    fi
}

# ==================== auto 安装辅助函数 ====================
# 检测解压后目录的包类型：binary/source/unknown
detect_package_type() {
    local dir="$1" mtype="${2:-}"
    [ -d "$dir" ] || { echo "unknown"; return 0; }

    # 源码标志
    [ -f "$dir/configure" ] || [ -f "$dir/Makefile" ] || [ -f "$dir/CMakeLists.txt" ] && { echo "source"; return 0; }
    ls "$dir"/src/*.c >/dev/null 2>&1 || ls "$dir"/src/*.cpp >/dev/null 2>&1 && { echo "source"; return 0; }

    # 二进制标志
    if [ -n "$mtype" ]; then
        for c in "$dir/sbin/$mtype" "$dir/bin/$mtype" "$dir/sbin/${mtype}d" "$dir/bin/${mtype}d"; do
            [ -x "$c" ] && { echo "binary"; return 0; }
        done
    fi
    for subdir in sbin bin; do
        [ -d "$dir/$subdir" ] || continue
        for f in "$dir/$subdir"/*; do
            [ -f "$f" ] && file "$f" 2>/dev/null | grep -q "ELF.*executable" && { echo "binary"; return 0; }
        done
    done
    echo "unknown"
}

# 智能解压包（支持 tar.gz/tgz/tar.xz/tar.bz2/zip/rpm）
install_binary_package() {
    local package_path="$1" deploy_dir="$2"
    [ -f "$package_path" ] || { log_error "包文件不存在: $package_path"; return 1; }
    mkdir -p "$deploy_dir" || { log_error "创建目录失败: $deploy_dir"; return 1; }

    log_info "[auto] 解压 $package_path -> $deploy_dir"
    case "$package_path" in
        *.tar.gz|*.tgz)  tar -xzf "$package_path" -C "$deploy_dir" --strip-components=1 || return 1 ;;
        *.tar.xz)        tar -xJf "$package_path" -C "$deploy_dir" --strip-components=1 || return 1 ;;
        *.tar.bz2)       tar -xjf "$package_path" -C "$deploy_dir" --strip-components=1 || return 1 ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || yum install -y unzip >/dev/null 2>&1 || { log_error "unzip 不可用"; return 1; }
            unzip -q -o "$package_path" -d "$deploy_dir" || return 1
            local subdirs=("$deploy_dir"/*/)
            if [ ${#subdirs[@]} -eq 1 ] && [ -d "${subdirs[0]}" ]; then
                mv "${subdirs[0]}"* "$deploy_dir/" 2>/dev/null || true
                rm -rf "${subdirs[0]}" 2>/dev/null || true
            fi
            ;;
        *.rpm)
            rpm -ivh --prefix="$deploy_dir" "$package_path" 2>/dev/null || {
                log_warn "[auto] rpm prefix 安装失败，尝试直接 rpm -ivh"
                rpm -ivh "$package_path" || return 1
            }
            ;;
        *)
            # file 命令兜底
            local ft; ft=$(file -b "$package_path" 2>/dev/null)
            case "$ft" in
                *gzip*)     tar -xzf "$package_path" -C "$deploy_dir" --strip-components=1 || return 1 ;;
                *XZ*)       tar -xJf "$package_path" -C "$deploy_dir" --strip-components=1 || return 1 ;;
                *bzip2*)    tar -xjf "$package_path" -C "$deploy_dir" --strip-components=1 || return 1 ;;
                *Zip*)      unzip -q -o "$package_path" -d "$deploy_dir" || return 1 ;;
                *RPM*)      rpm -ivh "$package_path" || return 1 ;;
                *) log_error "[auto] 不支持的包格式: $package_path ($ft)"; return 1 ;;
            esac
            ;;
    esac
    return 0
}

# 通用源码编译安装（configure/CMake/Makefile）
install_from_source() {
    local src_dir="$1" deploy_dir="$2" mtype="$3"
    [ -d "$src_dir" ] || { log_error "源码目录不存在: $src_dir"; return 1; }

    # 安装编译依赖
    local dep_count i dep
    dep_count=$(registry_get ".strategies.\"$mtype\".build_dependencies | length" "0")
    [ "$dep_count" != "0" ] && [ -n "$dep_count" ] && {
        for ((i=0; i<dep_count; i++)); do
            dep=$(registry_get ".strategies.\"$mtype\".build_dependencies[$i]" "")
            [ -n "$dep" ] && { log_info "[auto] 安装编译依赖: $dep"; yum install -y "$dep" >/dev/null 2>&1; }
        done
    }
    for tool in gcc make; do command -v "$tool" >/dev/null 2>&1 || yum install -y "$tool" >/dev/null 2>&1; done

    local configure_opts make_opts
    configure_opts=$(registry_get ".strategies.\"$mtype\".configure_options" "")
    make_opts=$(registry_get ".strategies.\"$mtype\".make_options" "")

    cd "$src_dir" || return 1

    if [ -f "$src_dir/configure" ]; then
        log_info "[auto] ./configure --prefix=$deploy_dir $configure_opts"
        ./configure --prefix="$deploy_dir" $configure_opts || { log_error "configure 失败"; return 1; }
        log_info "[auto] make -j$(nproc) $make_opts"
        make -j"$(nproc)" $make_opts || { log_error "make 失败"; return 1; }
        make install || { log_error "make install 失败"; return 1; }
    elif [ -f "$src_dir/CMakeLists.txt" ]; then
        command -v cmake >/dev/null 2>&1 || yum install -y cmake >/dev/null 2>&1
        mkdir -p "$src_dir/build" && cd "$src_dir/build" || return 1
        log_info "[auto] cmake -DCMAKE_INSTALL_PREFIX=$deploy_dir .."
        cmake -DCMAKE_INSTALL_PREFIX="$deploy_dir" $configure_opts .. || { log_error "cmake 失败"; return 1; }
        make -j"$(nproc)" $make_opts || { log_error "make 失败"; return 1; }
        make install || { log_error "make install 失败"; return 1; }
    elif [ -f "$src_dir/Makefile" ]; then
        log_info "[auto] make -j$(nproc) PREFIX=$deploy_dir $make_opts"
        if ! make -j"$(nproc)" PREFIX="$deploy_dir" $make_opts 2>/dev/null; then
            make -j"$(nproc)" $make_opts || { log_error "make 失败"; return 1; }
        fi
        if grep -q "install:" "$src_dir/Makefile" 2>/dev/null; then
            make install PREFIX="$deploy_dir" $make_opts 2>/dev/null || make install 2>/dev/null || true
        fi
        # 无 make install 时复制源码到部署目录
        if [ ! -d "$deploy_dir" ] || [ -z "$(ls -A "$deploy_dir" 2>/dev/null)" ]; then
            log_info "[auto] 无 make install，复制源码到部署目录"
            mkdir -p "$deploy_dir" && cp -a "$src_dir"/. "$deploy_dir"/
        fi
    else
        log_error "[auto] 未找到 configure/Makefile/CMakeLists.txt，无法编译"; return 1
    fi

    cd - >/dev/null 2>&1
    return 0
}
