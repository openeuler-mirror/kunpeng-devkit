#!/bin/bash
# ==============================================================================
# remote_exec.sh - 多节点环境信息采集与汇总脚本
# 支持本地和远程节点，支持多节点执行，最终汇总为一个 JSONC 文件
#
# 节点输入格式: "节点role,用户名@ip;节点role,用户名@ip"
#   - 节点role: 默认为 default
#   - 用户名:   默认为 root
#   - 根据 ip 自动判断本地执行或远程 SSH 执行
#
# 用法:
#   bash remote_exec.sh --nodes "master,root@192.168.1.1;worker,@192.168.1.2"
#   bash remote_exec.sh                                        # 本机执行
#   bash remote_exec.sh --parallel                             # 并行执行
#   bash remote_exec.sh --no-cleanup                           # 不清理远程临时文件
#   bash remote_exec.sh --help                                 # 显示帮助
# ==============================================================================

set -eu

# ============================ 默认配置 ============================

# 默认节点列表（新格式）："role,user@ip;role,user@ip"
# 示例: "master,@192.168.25.79;worker,@192.168.25.80;proxy,admin@127.0.0.1"
DEFAULT_NODES="default,@127.0.0.1"

# SSH 选项
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 远程临时目录
REMOTE_DIR="/tmp"

# 本地路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# 模板文件路径（兼容：与脚本同目录（拷贝到工作目录执行）或位于 skill assets/ 目录（就地执行））
TEMPLATE="${SCRIPT_DIR}/en.jsonc"
if [ ! -f "$TEMPLATE" ]; then
    TEMPLATE="${SCRIPT_DIR}/../assets/en.jsonc"
fi

# 输出目录（默认为当前工作目录，可通过 --output-dir 覆盖）
OUTPUT_DIR="$(pwd)"

# 并行执行标志
PARALLEL=0

# 清理标志
CLEANUP=1

# 结果目录
RESULTS_DIR="${OUTPUT_DIR}/results"

# ============================ 工具函数 ============================

usage() {
    cat <<EOF
用法: bash remote_exec.sh [选项]

节点输入格式: "节点role,用户名@ip;节点role,用户名@ip"
  节点role  - 默认: default  (可省略)
  用户名    - 默认: root     (可省略)
  根据 ip 自动判断: 127.0.0.1/localhost/本机IP => 本地执行, 其他 => 远程SSH执行

支持的简写形式:
  "192.168.1.1"                      => role=default, user=root,    远程
  "root@192.168.1.1"                 => role=default, user=root,    远程
  "@192.168.1.1"                     => role=default, user=root,    远程
  "master,192.168.1.1"               => role=master,  user=root,    远程
  "master,@192.168.1.1"              => role=master,  user=root,    远程
  "master,root@192.168.1.1"          => role=master,  user=root,    远程 (完整形式)
  "worker,admin@192.168.1.2"         => role=worker,  user=admin,   远程
  "127.0.0.1"                        => role=default, user=root,    本地
  "proxy,admin@localhost"            => role=proxy,   user=admin,   本地

选项:
  --nodes "节点串"  指定节点列表（分号分隔）
  --output-dir DIR  指定输出目录 (默认: 当前工作目录)
  --parallel        并行执行远程采集（默认串行）
  --no-cleanup      不清理远程临时文件
  --help, -h        显示此帮助信息

示例:
  # 使用默认节点
  bash remote_exec.sh

  # 单节点远程 (省略用户名)
  bash remote_exec.sh --nodes "master,@192.168.25.79"

  # 多节点混合: 2个远程 + 1个本地
  bash remote_exec.sh --nodes "master,@192.168.1.1;worker,@192.168.1.2;default,@127.0.0.1"

  # 多节点 + 不同用户名 + 并行执行
  bash remote_exec.sh --nodes "proxy,admin@10.0.0.1;worker,@10.0.0.2" --parallel

  # 指定输出目录
  bash remote_exec.sh --nodes "master,@192.168.25.79" --output-dir /path/to/workspace

注意:
  远程节点需要预先配置 SSH 免密登录，否则脚本会报错退出。
  配置方法:
    ssh-keygen -t rsa -b 2048        # 生成密钥(已有可跳过)
    ssh-copy-id root@远程IP          # 分发公钥
EOF
}

# 日志函数
log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

log_info() {
    echo ""
    echo "============================================"
    log "$*"
    echo "============================================"
    echo ""
}

log_success() {
    echo "[OK] $*"
}

log_warn() {
    echo "[WARN] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

# 获取本机所有 IP 地址（用于判断是否本地）
get_local_ips() {
    local ips=""
    # hostname -I 结果
    if command -v hostname &>/dev/null; then
        local host_ips
        host_ips=$(hostname -I 2>/dev/null || echo "")
        ips="$ips $host_ips"
    fi
    # ip 命令
    if command -v ip &>/dev/null; then
        local ip_ips
        ip_ips=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        ips="$ips $ip_ips"
    fi
    # ifconfig 回退
    if command -v ifconfig &>/dev/null; then
        local ifc_ips
        ifc_ips=$(ifconfig 2>/dev/null | awk '/inet / {print $2}' | grep -v '^addr:' | sed 's/addr://')
        ips="$ips $ifc_ips"
    fi
    # 回环地址
    ips="$ips 127.0.0.1 localhost 0.0.0.0"
    # 去重
    echo "$ips" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# 判断 IP 是否为本地
is_local_ip() {
    local target_ip="$1"
    local local_ips
    local_ips=$(get_local_ips)
    
    # 精确匹配
    for lip in $local_ips; do
        [[ "$target_ip" == "$lip" ]] && return 0
    done
    
    # 特殊判断：localhost 和 回环地址
    [[ "$target_ip" == "localhost" ]] && return 0
    [[ "$target_ip" == "127.0.0.1" ]] && return 0
    [[ "$target_ip" == "0.0.0.0" ]] && return 0
    
    return 1
}

# 检查远程节点是否已配置 SSH 免密登录
# 使用 BatchMode=yes，如果未配置免密则立即失败，不会卡在密码提示
# 返回: 0=免密可用, 1=免密不可用
check_ssh_passwordless() {
    local remote_user="$1"
    local remote_host="$2"
    
    # BatchMode=yes 禁用密码交互提示，ConnectTimeout=5 防止不可达主机长时间卡住
    ssh $SSH_OPTS -o BatchMode=yes  -o ConnectTimeout=5 \
        ${remote_user}@${remote_host} "echo ok" 2>/dev/null
}

# 解析单个节点配置
# 输入: "role,user@ip" 或简写形式
# 支持的简写:
#   "192.168.1.1"          => role=default, user=root, ip=192.168.1.1
#   "root@192.168.1.1"     => role=default, user=root, ip=192.168.1.1
#   "@192.168.1.1"         => role=default, user=root, ip=192.168.1.1
#   "master,192.168.1.1"   => role=master,  user=root, ip=192.168.1.1
#   "master,@192.168.1.1"  => role=master,  user=root, ip=192.168.1.1
#   "master,root@192.168.1.1" => 完整形式
# 输出: role user ip is_local (通过全局变量)
parse_node_spec() {
    local spec="$1"
    
    NODE_ROLE=""
    NODE_USER=""
    NODE_IP=""
    NODE_IS_LOCAL=0
    
    local part1=""   # role 或 user@ip
    local part2=""   # user@ip (如果有逗号)
    
    if [[ "$spec" == *","* ]]; then
        # 有逗号: "role,user@ip"
        part1="${spec%%,*}"   # role
        part2="${spec#*,}"    # user@ip
        # 去除 role 两端空格
        part1="${part1#"${part1%%[![:space:]]*}"}"
        part1="${part1%"${part1##*[![:space:]]}"}"
        NODE_ROLE="$part1"
    else
        # 无逗号: 直接是 user@ip
        part2="$spec"
        NODE_ROLE="default"
    fi
    
    # 去除 part2 两端空格
    part2="${part2#"${part2%%[![:space:]]*}"}"
    part2="${part2%"${part2##*[![:space:]]}"}"
    
    # 解析 part2 (user@ip)
    if [[ "$part2" == *"@"* ]]; then
        # user@ip 形式
        NODE_USER="${part2%%@*}"
        NODE_IP="${part2#*@}"
    else
        # 只有 ip，默认 root
        NODE_USER="root"
        NODE_IP="$part2"
    fi
    
    # 去除 IP 和 user 两端空格
    NODE_USER="${NODE_USER#"${NODE_USER%%[![:space:]]*}"}"
    NODE_USER="${NODE_USER%"${NODE_USER##*[![:space:]]}"}"
    NODE_IP="${NODE_IP#"${NODE_IP%%[![:space:]]*}"}"
    NODE_IP="${NODE_IP%"${NODE_IP##*[![:space:]]}"}"
    
    # 应用默认值
    [[ -z "$NODE_ROLE" ]] && NODE_ROLE="default"
    [[ -z "$NODE_USER" ]] && NODE_USER="root"
    
    # 判断本地/远程
    if [[ -n "$NODE_IP" ]] && is_local_ip "$NODE_IP"; then
        NODE_IS_LOCAL=1
    else
        NODE_IS_LOCAL=0
    fi
}

# ============================ 参数解析 ============================

NODE_LIST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)
            NODE_LIST="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            RESULTS_DIR="${OUTPUT_DIR}/results"
            shift 2
            ;;
        --parallel)
            PARALLEL=1
            shift
            ;;
        --no-cleanup)
            CLEANUP=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1 (使用 --help 查看帮助)" >&2
            exit 1
            ;;
    esac
done

# 应用默认值
NODE_LIST="${NODE_LIST:-$DEFAULT_NODES}"

# ============================ 节点采集函数 ============================

# 本地采集
collect_local() {
    local node_name="$1"
    local node_role="$2"
    local output_file="${RESULTS_DIR}/${node_name}.jsonc"

    log "本地执行采集脚本... (角色: ${node_role})"

    # 检查脚本和模板是否存在
    if [[ ! -f "${SCRIPT_DIR}/collect_env.sh" ]]; then
        log_error "采集脚本不存在: ${SCRIPT_DIR}/collect_env.sh"
        return 1
    fi
    if [[ ! -f "$TEMPLATE" ]]; then
        log_error "模板文件不存在: $TEMPLATE"
        return 1
    fi

    # 在本地执行（带 --role 覆盖，指定输出目录）
    bash "${SCRIPT_DIR}/collect_env.sh" --verbose --role "$node_role" --output-dir "$OUTPUT_DIR"
    local local_output="${OUTPUT_DIR}/en_info.jsonc"

    if [[ -f "$local_output" ]]; then
        cp "$local_output" "$output_file"
        log_success "本地采集完成，结果保存至: $output_file"
        return 0
    else
        log_error "本地采集失败，未生成结果文件"
        return 1
    fi
}

# 远程采集（使用 SSH + base64 管道传输，完全不依赖 scp）
collect_remote() {
    local node_name="$1"
    local node_role="$2"
    local remote_user="$3"
    local remote_host="$4"
    local output_file="${RESULTS_DIR}/${node_name}.jsonc"

    log "远程执行采集脚本 (${remote_user}@${remote_host}, 角色: ${node_role})..."

    # 检查本地文件
    if [[ ! -f "${SCRIPT_DIR}/collect_env.sh" ]]; then
        log_error "采集脚本不存在: ${SCRIPT_DIR}/collect_env.sh"
        return 1
    fi
    if [[ ! -f "$TEMPLATE" ]]; then
        log_error "模板文件不存在: $TEMPLATE"
        return 1
    fi

    local remote_workdir="${REMOTE_DIR}/env_collect_${node_name}"
    local script_b64
    local template_b64
    script_b64=$(base64 -w 0 "${SCRIPT_DIR}/collect_env.sh" 2>/dev/null || base64 "${SCRIPT_DIR}/collect_env.sh" | tr -d '\n')
    template_b64=$(base64 -w 0 "$TEMPLATE" 2>/dev/null || base64 "$TEMPLATE" | tr -d '\n')

    # 1. 通过 base64 管道传输文件（避免 heredoc 分隔符冲突）
    log "  创建远程目录并传输文件 (base64管道)..."
    ssh $SSH_OPTS ${remote_user}@${remote_host} \
        "mkdir -p '${remote_workdir}' && cd '${remote_workdir}' && echo '${script_b64}' | base64 -d > collect_env.sh && echo '${template_b64}' | base64 -d > en.jsonc && chmod +x collect_env.sh"

    # 2. 远程执行（带 --role 覆盖）
    log "  执行采集脚本..."
    ssh $SSH_OPTS ${remote_user}@${remote_host} "
        cd '${remote_workdir}'
        bash collect_env.sh --verbose --role '${node_role}'
    "

    # 3. 下载结果（通过 SSH + base64 编码回传，避免终端控制字符干扰）
    log "  下载结果..."
    ssh $SSH_OPTS ${remote_user}@${remote_host} "base64 -w 0 '${remote_workdir}/en_info.jsonc' 2>/dev/null || base64 '${remote_workdir}/en_info.jsonc' | tr -d '\n'" \
        | base64 -d > "$output_file" 2>/dev/null || true

    # 4. 清理远程文件
    if [[ "$CLEANUP" == "1" ]]; then
        log "  清理远程临时文件..."
        ssh $SSH_OPTS ${remote_user}@${remote_host} "rm -rf '${remote_workdir}'" 2>/dev/null || true
    fi

    # 验证下载结果
    if [[ -f "$output_file" && -s "$output_file" ]]; then
        log_success "远程采集完成 (${remote_host})，结果保存至: $output_file"
        return 0
    else
        log_error "远程采集失败 (${remote_host})，未下载到结果文件或文件为空"
        rm -f "$output_file"
        return 1
    fi
}

# ============================ 数据汇总函数 ============================

merge_results() {
    local merged_file="${OUTPUT_DIR}/env_info.jsonc"

    log_info "汇总多节点数据..."

    # 收集所有节点结果文件
    local result_files=()

    while IFS= read -r -d '' f; do
        result_files+=("$f")
    done < <(find "$RESULTS_DIR" -maxdepth 1 -name "*.jsonc" ! -name "_*" -print0 2>/dev/null | sort -z)

    if [[ ${#result_files[@]} -eq 0 ]]; then
        log_error "没有找到任何采集结果文件"
        return 1
    fi

    log "找到 ${#result_files[@]} 个结果文件"

    log "使用纯 bash 进行合并..."
    merge_with_bash "$merged_file" "${result_files[@]}" || return 1

    log_success "数据汇总完成: $merged_file"

    # 显示汇总结果摘要
    node_count=$(grep -c '"ip":' "$merged_file" 2>/dev/null || echo "?")
    log "汇总节点数: $node_count"

    return 0
}

# 纯 bash 合并实现（简单拼接，保证可读性）
merge_with_bash() {
    local merged_file="$1"; shift
    local result_files=("$@")

    log "纯 bash 合并..."
    {
        echo "{"
        echo '  "environment": {'
        echo '    "nodes": ['

        local first=1
        for filepath in "${result_files[@]}"; do
            local node_name
            node_name=$(basename "$filepath" .jsonc)

            if [[ $first -eq 0 ]]; then
                echo ","
            fi
            first=0

            echo "      // ===== 节点: ${node_name} ====="
            cat "$filepath"
        done

        echo ""
        echo "    ]"
        echo "  }"
        echo "}"
    } > "$merged_file"

    log "bash 合并完成（原始 JSONC 拼接，格式可能不标准）"
    log "提示：在 Linux 上安装 python3 或 jq 可获得正确的 JSON 合并结果"
    return 0
}

# ============================ 主流程 ============================

main() {
    log_info "多节点环境信息采集"
    log "节点列表: $NODE_LIST"
    log "输出目录: $OUTPUT_DIR"
    log "并行模式: $([ "$PARALLEL" == "1" ] && echo "是" || echo "否")"
    log "清理临时文件: $([ "$CLEANUP" == "1" ] && echo "是" || echo "否")"

    # 创建结果目录
    if [[ -d "$RESULTS_DIR" ]]; then
        log_info "结果目录已存在: $RESULTS_DIR"
        rm -rf "$RESULTS_DIR"
    fi
    mkdir -p "$RESULTS_DIR"

    # 解析节点列表（分号分隔）
    local nodes_raw=()
    IFS=';' read -ra nodes_raw <<< "$NODE_LIST"

    # 用于存储解析后的节点信息数组（每个元素是 "role|user|ip|is_local"）
    local -a parsed_nodes=()
    local -a parsed_nodes_desc=()

    for node_spec in "${nodes_raw[@]}"; do
        # trim whitespace
        node_spec="${node_spec#"${node_spec%%[![:space:]]*}"}"
        node_spec="${node_spec%"${node_spec##*[![:space:]]}"}"
        [[ -z "$node_spec" ]] && continue

        # 解析节点配置
        parse_node_spec "$node_spec"

        # 校验必填字段
        if [[ -z "$NODE_IP" ]]; then
            log_warn "跳过无效节点配置 (无IP): [$node_spec]"
            continue
        fi

        # 构建描述字符串
        local exec_type
        if [[ "$NODE_IS_LOCAL" == "1" ]]; then
            exec_type="本地"
        else
            exec_type="远程"
        fi

        local desc="[${NODE_ROLE}] ${NODE_USER}@${NODE_IP} (${exec_type})"
        parsed_nodes_desc+=("$desc")

        # 存储解析结果
        parsed_nodes+=("${NODE_ROLE}|${NODE_USER}|${NODE_IP}|${NODE_IS_LOCAL}")
    done

    if [[ ${#parsed_nodes[@]} -eq 0 ]]; then
        log_error "没有有效的节点配置"
        exit 1
    fi

    log_info "解析到 ${#parsed_nodes[@]} 个节点:"
    for desc in "${parsed_nodes_desc[@]}"; do
        log "  - $desc"
    done

    # 采集前检查所有远程节点的 SSH 免密登录
    local has_remote=0
    for parsed in "${parsed_nodes[@]}"; do
        local _role _user _ip _is_local
        IFS='|' read -r _role _user _ip _is_local <<< "$parsed"
        [[ "$_is_local" == "1" ]] && continue
        has_remote=1
        break
    done

    if [[ "$has_remote" == "1" ]]; then
        log_info "检查远程节点 SSH 免密登录..."
        local ssh_failed=()
        for parsed in "${parsed_nodes[@]}"; do
            local _role _user _ip _is_local
            IFS='|' read -r _role _user _ip _is_local <<< "$parsed"
            [[ "$_is_local" == "1" ]] && continue

            log "  检查免密: ${_user}@${_ip} ..."
            if check_ssh_passwordless "$_user" "$_ip"; then
                log_success "  免密可用: ${_user}@${_ip}"
            else
                log_error "  免密不可用: ${_user}@${_ip}"
                ssh_failed+=("${_user}@${_ip}")
            fi
        done

        if [[ ${#ssh_failed[@]} -gt 0 ]]; then
            log_error "以下远程节点未配置 SSH 免密登录: ${ssh_failed[*]}"
            log "  请先配置免密登录，示例:"
            log "    ssh-keygen -t rsa -b 2048          # 生成密钥(如已有可跳过)"
            log "    ssh-copy-id ${ssh_failed[0]}       # 分发公钥到远程节点"
            log "  或使用 ssh-passbypass 工具，但推荐免密方式"
            exit 1
        fi
    fi

    log_info "开始采集..."

    local failed_nodes=()
    local pids=()
    local pid_nodes=()

    # 采集每个节点
    local idx=0
    for parsed in "${parsed_nodes[@]}"; do
        local node_role node_user node_ip node_is_local
        IFS='|' read -r node_role node_user node_ip node_is_local <<< "$parsed"

        # 生成节点名（用于文件名）
        local node_name
        node_name="${node_role}_${node_user}_${node_ip}"
        node_name="${node_name//[^a-zA-Z0-9_]/_}"   # 替换非法字符

        local node_desc="${parsed_nodes_desc[$idx]}"
        idx=$((idx + 1))

        local node_type="remote"
        [[ "$node_is_local" == "1" ]] && node_type="local"

        if [[ "$PARALLEL" == "1" && "$node_type" == "remote" ]]; then
            # 并行模式：后台执行
            log "  [并行] 启动采集: $node_desc"
            (
                if [[ "$node_type" == "local" ]]; then
                    collect_local "$node_name" "$node_role"
                else
                    collect_remote "$node_name" "$node_role" "$node_user" "$node_ip"
                fi
            ) &
            pids+=($!)
            pid_nodes+=("$node_desc")
        else
            # 串行模式：前台执行
            log "  [串行] 执行采集: $node_desc"
            if [[ "$node_type" == "local" ]]; then
                collect_local "$node_name" "$node_role" || failed_nodes+=("$node_desc")
            else
                collect_remote "$node_name" "$node_role" "$node_user" "$node_ip" || failed_nodes+=("$node_desc")
            fi
        fi
    done

    # 等待并行任务完成
    if [[ "$PARALLEL" == "1" && ${#pids[@]} -gt 0 ]]; then
        log_info "等待并行任务完成..."
        for i in "${!pids[@]}"; do
            local pid="${pids[$i]}"
            local node_cfg="${pid_nodes[$i]}"
            if ! wait "$pid"; then
                failed_nodes+=("$node_cfg")
                log_error "并行任务失败: $node_cfg"
            else
                log_success "并行任务完成: $node_cfg"
            fi
        done
    fi

    # 检查是否有成功的结果
    local success_count
    success_count=$(find "$RESULTS_DIR" -maxdepth 1 -name "*.jsonc" ! -name "_*" 2>/dev/null | wc -l)

    if [[ "$success_count" -eq 0 ]]; then
        log_error "所有节点采集均失败"
        exit 1
    fi

    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        log_warn "部分节点采集失败: ${failed_nodes[*]}"
    fi

    # 汇总结果
    merge_results || log_error "数据汇总失败"

    # 显示最终结果
    log_info "采集任务完成!"

    local merged_file="${OUTPUT_DIR}/env_info.jsonc"
    log_success "数据汇总完成: $merged_file"
}

# 执行主流程
main "$@"