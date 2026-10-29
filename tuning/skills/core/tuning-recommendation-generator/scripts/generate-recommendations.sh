#!/bin/bash
# generate-recommendations.sh - 自动生成调优建议报告
# 用法: ./generate-recommendations.sh [工作目录]
# 如果不指定工作目录，默认使用当前目录

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 工作目录
WORKDIR="${1:-$(pwd)}"
cd "$WORKDIR"

echo -e "${BLUE}=== 调优建议生成器 ===${NC}"
echo -e "${BLUE}工作目录: $WORKDIR${NC}"
echo ""

# 生成时间戳
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="tuning_recommendations_${TIMESTAMP}.md"

# 数值比较函数（替代bc）
compare_value() {
    local value="$1"
    local threshold="$2"
    local operator="$3"
    
    if [[ "$value" == "N/A" ]] || [[ ! "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 1
    fi
    
    awk "BEGIN { exit ($value $operator $threshold) }"
}

# 提取数值函数（替代grep -oP）
extract_number() {
    local file="$1"
    local pattern="$2"
    local default="$3"
    
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    
    local result=$(grep -E "$pattern" "$file" | awk '{for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.?[0-9]*%/) {gsub(/%/,"",$i); print $i; exit} else if($i ~ /[0-9]+\.?[0-9]*/) {print $i; exit}}' | head -1)
    
    if [[ -z "$result" ]] || [[ ! "$result" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

echo -e "${YELLOW}[Phase 1] 数据文件检查${NC}"

# 必需的数据文件列表
REQUIRED_FILES=(
    "static_info.txt"
    "global_bottleneck.txt"
    "top_processes.txt"
)

# 可选的OS级分析结果文件
OPTIONAL_OS_FILES=(
    "hotspot_analysis.txt"
    "syscall_analysis.txt"
    "microarch_analysis.txt"
    "io_metrics_analysis.txt"
    "lock_trace_analysis.txt"
    "memory_metrics_analysis.txt"
    "network_metrics_analysis.txt"
    "scheduler_trace_analysis.txt"
    "cpu_detail_info.txt"
    "kernel_config_info.txt"
    "pmu_info.txt"
    "process_detail_info.txt"
    "system_detail_info.txt"
    "container_info.txt"
)

# 可选的DevKit数据文件列表
OPTIONAL_DEVKIT_FILES=(
    "devkit_hotspot.txt"
    "devkit_kspect.txt"
    "devkit_ksys.txt"
    "devkit_memory.txt"
    "devkit_numafast.txt"
    "devkit_topdown.txt"
    "devkit_turbostat.txt"
)

# 补充数据文件
SUPPLEMENT_FILES=(
    "software.txt"
    "supple_data.txt"
)

# 场景化分析结果目录
SCENARIO_BOTTLENECK_DIR="bottleneck-analysis"
SCENARIO_TUNING_DIR="tuning-report"

# 检查必需文件
MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        MISSING_FILES+=("$file")
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    echo -e "${RED}错误: 缺少必需的数据文件:${NC}"
    for file in "${MISSING_FILES[@]}"; do
        echo -e "  ${RED}- $file${NC}"
    done
    echo -e "${YELLOW}建议: 先运行 server_data_collector.sh 完成数据采集${NC}"
    exit 1
fi

echo -e "${GREEN}必需文件检查通过${NC}"

# 检查可选文件
echo -e "${YELLOW}OS级分析文件检查:${NC}"
for file in "${OPTIONAL_OS_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓ $file${NC}"
    else
        echo -e "  ${YELLOW}○ $file (缺失)${NC}"
    fi
done

echo -e "${YELLOW}DevKit数据文件检查:${NC}"
for file in "${OPTIONAL_DEVKIT_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓ $file${NC}"
    else
        echo -e "  ${YELLOW}○ $file (缺失)${NC}"
    fi
done

echo -e "${YELLOW}补充数据文件检查:${NC}"
for file in "${SUPPLEMENT_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓ $file${NC}"
    else
        echo -e "  ${YELLOW}○ $file (缺失)${NC}"
    fi
done

# 检查场景化分析结果
if [ -d "$SCENARIO_BOTTLENECK_DIR" ]; then
    echo -e "${GREEN}✓ 场景化瓶颈分析目录存在: $SCENARIO_BOTTLENECK_DIR${NC}"
else
    echo -e "${YELLOW}○ 场景化瓶颈分析目录缺失: $SCENARIO_BOTTLENECK_DIR${NC}"
fi

if [ -d "$SCENARIO_TUNING_DIR" ]; then
    echo -e "${GREEN}✓ 场景化调优目录存在: $SCENARIO_TUNING_DIR${NC}"
else
    echo -e "${YELLOW}○ 场景化调优目录缺失: $SCENARIO_TUNING_DIR${NC}"
fi

echo ""

# 提取系统环境信息
echo -e "${YELLOW}[Phase 2] 提取系统环境信息${NC}"

CPU_INFO=$(grep -E "CPU|Processor|型号|核心" static_info.txt | head -5 || echo "未找到CPU信息")
MEM_INFO=$(grep -E "Memory|内存|Total" static_info.txt | head -3 || echo "未找到内存信息")
DISK_INFO=$(grep -E "Disk|磁盘|sda|nvme|vda" static_info.txt | head -5 || echo "未找到磁盘信息")
OS_INFO=$(grep -E "OS|Kernel|内核|发行版" static_info.txt | head -5 || echo "未找到操作系统信息")
NUMA_INFO=$(grep -E "NUMA|node" static_info.txt | head -5 || echo "未找到NUMA信息")

echo -e "${GREEN}系统环境信息提取完成${NC}"
echo ""

# 提取软件版本信息（用于调优命令修正）
SOFTWARE_VERSIONS=""
if [ -f "software.txt" ]; then
    SOFTWARE_VERSIONS=$(cat software.txt)
    echo -e "${GREEN}软件版本信息已加载${NC}"
fi

SUPPLE_DATA=""
if [ -f "supple_data.txt" ]; then
    SUPPLE_DATA=$(cat supple_data.txt)
    echo -e "${GREEN}补充数据已加载${NC}"
fi

echo ""

# 分析瓶颈指标
echo -e "${YELLOW}[Phase 3] 分析瓶颈指标${NC}"

# 从global_bottleneck.txt提取关键指标
CPU_IOWAIT=$(extract_number "global_bottleneck.txt" "iowait" "N/A")
CPU_USER=$(extract_number "global_bottleneck.txt" "user" "N/A")
DISK_UTIL=$(extract_number "global_bottleneck.txt" "util" "N/A")
DISK_AWAIT=$(extract_number "global_bottleneck.txt" "await" "N/A")
MEM_USED=$(extract_number "global_bottleneck.txt" "MemUsed|内存使用" "N/A")
SWAP_USED=$(extract_number "global_bottleneck.txt" "SwapUsed|swap" "N/A")

echo -e "  CPU iowait: ${CPU_IOWAIT}%"
echo -e "  CPU user: ${CPU_USER}%"
echo -e "  Disk util: ${DISK_UTIL}%"
echo -e "  Disk await: ${DISK_AWAIT}ms"
echo -e "  Memory used: ${MEM_USED}%"
echo -e "  Swap used: ${SWAP_USED}%"

# 从microarch_analysis.txt提取微架构指标
if [ -f "microarch_analysis.txt" ]; then
    L1_MISS=$(extract_number "microarch_analysis.txt" "L1.*miss|L1-dcache" "N/A")
    LLC_MISS=$(extract_number "microarch_analysis.txt" "LLC.*miss|cache-misses" "N/A")
    BRANCH_MISS=$(extract_number "microarch_analysis.txt" "branch.*miss|branch-misses" "N/A")
    IPC=$(extract_number "microarch_analysis.txt" "IPC|instructions" "N/A")
    
    echo -e "  L1 cache miss: ${L1_MISS}%"
    echo -e "  LLC cache miss: ${LLC_MISS}%"
    echo -e "  Branch miss: ${BRANCH_MISS}%"
    echo -e "  IPC: ${IPC}"
fi

# 从devkit_topdown.txt提取Topdown指标
if [ -f "devkit_topdown.txt" ]; then
    FRONTEND_BOUND=$(extract_number "devkit_topdown.txt" "Frontend.*Bound|前端瓶颈" "N/A")
    BACKEND_BOUND=$(extract_number "devkit_topdown.txt" "Backend.*Bound|后端瓶颈" "N/A")
    BAD_SPECULATION=$(extract_number "devkit_topdown.txt" "Bad.*Speculation|错误推测" "N/A")
    RETIRING=$(extract_number "devkit_topdown.txt" "Retiring| retiring" "N/A")
    
    echo -e "  Frontend Bound: ${FRONTEND_BOUND}%"
    echo -e "  Backend Bound: ${BACKEND_BOUND}%"
    echo -e "  Bad Speculation: ${BAD_SPECULATION}%"
    echo -e "  Retiring: ${RETIRING}%"
fi

# 从devkit_memory.txt提取内存指标
if [ -f "devkit_memory.txt" ]; then
    L2D_MISS=$(extract_number "devkit_memory.txt" "L2D.*miss|L2.*miss" "N/A")
    LLC_MISS_RATE=$(extract_number "devkit_memory.txt" "LLC.*miss|Last.*Level" "N/A")
    MEM_BANDWIDTH=$(extract_number "devkit_memory.txt" "bandwidth|带宽|MB/s" "N/A")
    
    echo -e "  L2D miss: ${L2D_MISS}%"
    echo -e "  LLC miss rate: ${LLC_MISS_RATE}%"
    echo -e "  Memory bandwidth: ${MEM_BANDWIDTH} MB/s"
fi

# 从devkit_numafast.txt提取NUMA指标
if [ -f "devkit_numafast.txt" ]; then
    NUMA_SCORE=$(extract_number "devkit_numafast.txt" "NUMA.*score|score" "N/A")
    CROSS_NUMA=$(extract_number "devkit_numafast.txt" "cross.*NUMA|跨NUMA" "N/A")
    
    echo -e "  NUMA score: ${NUMA_SCORE}"
    echo -e "  Cross NUMA access: ${CROSS_NUMA}%"
fi

# 从io_metrics_analysis.txt提取I/O瓶颈信息
IO_BOTTLENECK=""
if [ -f "io_metrics_analysis.txt" ]; then
    IO_BOTTLENECK=$(grep -E "瓶颈状态|Bottleneck|Critical|High" io_metrics_analysis.txt | head -5)
    echo -e "${GREEN}I/O瓶颈分析文件已加载${NC}"
fi

# 从memory_metrics_analysis.txt提取内存瓶颈信息
MEM_BOTTLENECK=""
if [ -f "memory_metrics_analysis.txt" ]; then
    MEM_BOTTLENECK=$(grep -E "瓶颈状态|Bottleneck|Critical|High" memory_metrics_analysis.txt | head -5)
    echo -e "${GREEN}内存瓶颈分析文件已加载${NC}"
fi

# 从network_metrics_analysis.txt提取网络瓶颈信息
NET_BOTTLENECK=""
if [ -f "network_metrics_analysis.txt" ]; then
    NET_BOTTLENECK=$(grep -E "瓶颈状态|Bottleneck|Critical|High" network_metrics_analysis.txt | head -5)
    echo -e "${GREEN}网络瓶颈分析文件已加载${NC}"
fi

# 从scheduler_trace_analysis.txt提取调度瓶颈信息
SCHED_BOTTLENECK=""
if [ -f "scheduler_trace_analysis.txt" ]; then
    SCHED_BOTTLENECK=$(grep -E "瓶颈状态|Bottleneck|Critical|High" scheduler_trace_analysis.txt | head -5)
    echo -e "${GREEN}调度器瓶颈分析文件已加载${NC}"
fi

# 从lock_trace_analysis.txt提取锁瓶颈信息
LOCK_BOTTLENECK=""
if [ -f "lock_trace_analysis.txt" ]; then
    LOCK_BOTTLENECK=$(grep -E "瓶颈状态|Bottleneck|Critical|High" lock_trace_analysis.txt | head -5)
    echo -e "${GREEN}锁瓶颈分析文件已加载${NC}"
fi

echo ""

# 生成调优建议报告
echo -e "${YELLOW}[Phase 4] 生成调优建议报告${NC}"

cat > "$REPORT_FILE" << EOF
# 系统调优建议报告

**生成时间**: $(date +"%Y-%m-%d %H:%M:%S")
**分析目录**: $WORKDIR

## 系统环境信息

### CPU信息
$CPU_INFO

### 内存信息
$MEM_INFO

### NUMA信息
$NUMA_INFO

### 磁盘信息
$DISK_INFO

### 操作系统信息
$OS_INFO

EOF

# 添加软件版本信息
if [ -n "$SOFTWARE_VERSIONS" ]; then
    cat >> "$REPORT_FILE" << EOF

### 软件版本信息
\`\`\`
$SOFTWARE_VERSIONS
\`\`\`

EOF
fi

cat >> "$REPORT_FILE" << EOF

---

## 调优建议汇总表

| 瓶颈描述 | 调优方案 | 关联的性能数据 | 关联的调优手段 | 具体的执行步骤 | 调用的技能 |
|---------|---------|--------------|-------------------|--------------|-----------|

EOF

# 生成调优建议表格行
RECOMMENDATION_COUNT=0

# I/O瓶颈建议
if compare_value "$DISK_UTIL" 90 ">"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **磁盘I/O饱和**<br><br>磁盘利用率达到${DISK_UTIL}%，超过90%阈值，I/O等待时间${DISK_AWAIT}ms，严重影响系统响应速度。<br><br>严重程度: **Critical**<br>影响进程: mysqld, jbd2 | **调优方向**:<br>优化I/O调度器，减少I/O等待延迟<br><br>**预期效果**:<br>磁盘util降低到70%以下，I/O等待时间降低到20ms以内<br><br>**风险评估**: 低 | **关键指标**:<br>- %util: ${DISK_UTIL}% (阈值: 90%, 状态: Critical)<br>- await: ${DISK_AWAIT}ms (阈值: 20ms, 状态: High)<br>- %iowait: ${CPU_IOWAIT}% (阈值: 20%, 状态: Critical) | **参数1**: /sys/block/sda/queue/scheduler<br>- 说明: I/O调度器<br>- 推荐值: mq-deadline<br>- 调整命令: \`echo mq-deadline > /sys/block/sda/queue/scheduler\`<br><br>**参数2**: vm.dirty_ratio<br>- 说明: dirty page占比上限<br>- 推荐值: 10<br>- 调整命令: \`sysctl -w vm.dirty_ratio=10\` | **步骤1**: 切换I/O调度器<br>\`\`\`bash<br>echo mq-deadline > /sys/block/sda/queue/scheduler<br>\`\`\`<br><br>**步骤2**: 调整dirty_ratio<br>\`\`\`bash<br>sysctl -w vm.dirty_ratio=10<br>sysctl -w vm.dirty_background_ratio=5<br>\`\`\`<br><br>**步骤3**: 监控效果<br>\`\`\`bash<br>iostat -xz 5 10<br>\`\`\` | opentunex-io-bottleneck |
EOF
fi

# CPU I/O等待瓶颈建议
if compare_value "$CPU_IOWAIT" 20 ">"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **CPU I/O等待过高**<br><br>CPU花费${CPU_IOWAIT}%时间等待I/O完成，超过20%阈值，导致整体响应延迟增加。<br><br>严重程度: **High**<br>影响进程: 所有I/O密集型进程 | **调优方向**:<br>优化磁盘I/O策略，减少I/O阻塞<br><br>**预期效果**:<br>CPU iowait从${CPU_IOWAIT}%降低到15%以下<br><br>**风险评估**: 中 | **关键指标**:<br>- %iowait: ${CPU_IOWAIT}% (阈值: 20%, 状态: High)<br>- %util: ${DISK_UTIL}% (阈值: 90%) | **参数1**: vm.dirty_background_ratio<br>- 说明: 后台写回触发比例<br>- 推荐值: 5<br>- 调整命令: \`sysctl -w vm.dirty_background_ratio=5\`<br><br>**参数2**: vm.dirty_writeback_centisecs<br>- 说明: 后台写回间隔<br>- 推荐值: 300<br>- 调整命令: \`sysctl -w vm.dirty_writeback_centisecs=300\` | **步骤1**: 调整后台写回参数<br>\`\`\`bash<br>sysctl -w vm.dirty_background_ratio=5<br>sysctl -w vm.dirty_writeback_centisecs=300<br>\`\`\`<br><br>**步骤2**: 监控效果<br>\`\`\`bash<br>vmstat 5 10<br>\`\`\` | opentunex-io-bottleneck |
EOF
fi

# 内存瓶颈建议
if compare_value "$MEM_USED" 90 ">"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **内存使用率过高**<br><br>内存使用率达到${MEM_USED}%，超过90%阈值，可能导致OOM或频繁swap。<br><br>严重程度: **Critical**<br>影响进程: 所有进程 | **调优方向**:<br>优化内存回收策略，减少swap使用<br><br>**预期效果**:<br>内存使用率降低到80%以下<br><br>**风险评估**: 中 | **关键指标**:<br>- Memory used: ${MEM_USED}% (阈值: 90%, 状态: Critical)<br>- Swap used: ${SWAP_USED}% | **参数1**: vm.swappiness<br>- 说明: swap使用倾向<br>- 推荐值: 10<br>- 调整命令: \`sysctl -w vm.swappiness=10\`<br><br>**参数2**: vm.vfs_cache_pressure<br>- 说明: VFS缓存回收压力<br>- 推荐值: 150<br>- 调整命令: \`sysctl -w vm.vfs_cache_pressure=150\` | **步骤1**: 调整swap策略<br>\`\`\`bash<br>sysctl -w vm.swappiness=10<br>\`\`\`<br><br>**步骤2**: 监控内存<br>\`\`\`bash<br>free -m<br>vmstat 5 10<br>\`\`\` | opentunex-mem-bottleneck |
EOF
fi

# 缓存缺失瓶颈建议
if compare_value "$L1_MISS" 10 ">"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **L1缓存缺失率高**<br><br>L1数据缓存缺失率达到${L1_MISS}%，超过10%阈值，影响CPU性能。<br><br>严重程度: **Medium**<br>影响进程: CPU密集型进程 | **调优方向**:<br>启用透明巨页，减少内存访问延迟<br><br>**预期效果**:<br>L1缓存缺失率降低到10%以下<br><br>**风险评估**: 中 | **关键指标**:<br>- L1 miss rate: ${L1_MISS}% (阈值: 10%, 状态: Medium) | **参数1**: /sys/kernel/mm/transparent_hugepage/enabled<br>- 说明: 透明巨页启用状态<br>- 推荐值: always<br>- 调整命令: \`echo always > /sys/kernel/mm/transparent_hugepage/enabled\`<br><br>**参数2**: vm.nr_hugepages<br>- 说明: 巨页数量<br>- 推荐值: 根据内存计算<br>- 调整命令: \`sysctl -w vm.nr_hugepages=N\` | **步骤1**: 启用THP<br>\`\`\`bash<br>echo always > /sys/kernel/mm/transparent_hugepage/enabled<br>\`\`\`<br><br>**步骤2**: 监控效果<br>\`\`\`bash<br>perf stat -e cache-references,cache-misses sleep 10<br>\`\`\` | opentunex-mem-bottleneck |
EOF
fi

# 分支预测瓶颈建议
if compare_value "$BRANCH_MISS" 5 ">"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **分支预测失败率高**<br><br>分支预测失败率达到${BRANCH_MISS}%，超过5%阈值，影响指令流水线效率。<br><br>严重程度: **Medium**<br>影响进程: CPU密集型进程 | **调优方向**:<br>编译器级别优化，减少进程迁移<br><br>**预期效果**:<br>分支预测失败率降低到5%以下<br><br>**风险评估**: 中 | **关键指标**:<br>- branch miss rate: ${BRANCH_MISS}% (阈值: 5%, 状态: Medium) | **参数1**: kernel.sched_migration_cost_ns<br>- 说明: 进程迁移成本<br>- 推荐值: 1000000<br>- 调整命令: \`sysctl -w kernel.sched_migration_cost_ns=1000000\`<br><br>**编译器参数**:<br>- 选项: \`-fprofile-use -fbranch-probabilities\`<br>- 说明: Profile-guided优化 | **步骤1**: 减少进程迁移<br>\`\`\`bash<br>sysctl -w kernel.sched_migration_cost_ns=1000000<br>\`\`\`<br><br>**步骤2**: (可选) PGO编译<br>\`\`\`bash<br>gcc -fprofile-generate -O3 app.c -o app<br>./app  # 训练负载<br>gcc -fprofile-use -fbranch-probabilities -O3 app.c -o app<br>\`\`\` | devkit-topdown-analysis |
EOF
fi

# Topdown Backend Bound瓶颈（Kunpeng-920）
if compare_value "$BACKEND_BOUND" 70 ">"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **后端瓶颈严重**<br><br>Backend Bound达到${BACKEND_BOUND}%，超过70%阈值，CPU执行效率严重受限。<br><br>严重程度: **Critical**<br>影响进程: 所有CPU密集型进程 | **调优方向**:<br>优化内存访问、NUMA绑定、编译器优化<br><br>**预期效果**:<br>Backend Bound降低到50%以下，IPC提升<br><br>**风险评估**: 中 | **关键指标**:<br>- Backend Bound: ${BACKEND_BOUND}% (阈值: 70%, 状态: Critical)<br>- IPC: ${IPC} (正常: 0.5-2.0)<br>- L2D miss: ${L2D_MISS}% | **参数1**: numactl绑定策略<br>- 说明: NUMA内存绑定<br>- 推荐策略: 绑定到本地NUMA节点<br>- 调整命令: \`numactl --membind=0 --cpunodebind=0 <command>\`<br><br>**编译器参数**:<br>- BiSheng: \`-march=armv8.2-a+crypto+sve -mtune=kunpeng920\`<br>- Prefetch: \`-fprefetch-loop-arrays\` | **步骤1**: NUMA绑定<br>\`\`\`bash<br>numactl --membind=0 --cpunodebind=0 ./your_app<br>\`\`\`<br><br>**步骤2**: 编译器优化<br>\`\`\`bash<br># BiSheng编译器<br>bishengcc -march=armv8.2-a+crypto+sve -mtune=kunpeng920 -O3 app.c<br>\`\`\`<br><br>**步骤3**: 监控效果<br>\`\`\`bash<br>devkit tuner top-down -d 30 -p <PID><br>\`\`\` | devkit-topdown-analysis |
EOF
fi

# NUMA瓶颈建议
if compare_value "$NUMA_SCORE" 0.5 "<"; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **NUMA性能评分低**<br><br>NUMA性能评分${NUMA_SCORE}，低于0.5阈值，存在跨NUMA访问瓶颈。<br><br>严重程度: **High**<br>影响进程: 内存密集型进程 | **调优方向**:<br>优化NUMA绑定策略，启用NUMA调度优化<br><br>**预期效果**:<br>NUMA评分提升到0.7以上<br><br>**风险评估**: 中 | **关键指标**:<br>- NUMA score: ${NUMA_SCORE} (阈值: 0.5, 状态: High)<br>- Cross NUMA: ${CROSS_NUMA}% | **参数1**: kernel.numa_balancing<br>- 说明: NUMA自动平衡<br>- 推荐值: 1 (启用)<br>- 调整命令: \`sysctl -w kernel.numa_balancing=1\`<br><br>**参数2**: numactl策略<br>- 说明: 手动NUMA绑定<br>- 推荐策略: 绑定本地节点 | **步骤1**: 启用NUMA平衡<br>\`\`\`bash<br>sysctl -w kernel.numa_balancing=1<br>\`\`\`<br><br>**步骤2**: NUMA绑定启动<br>\`\`\`bash<br>numactl --interleave=all ./your_app<br># 或绑定到特定节点<br>numactl --membind=0 --cpunodebind=0 ./your_app<br>\`\`\`<br><br>**备注**: 调优脚本: numa_sched_tune.sh | devkit-numafast-analysis<br>opentunex-numa-sched-tuning |
EOF
fi

# 从场景化调优结果中提取建议
if [ -d "$SCENARIO_TUNING_DIR" ]; then
    # 查找最新的调优报告
    LATEST_TUNING=$(ls -td "$SCENARIO_TUNING_DIR"/*/ 2>/dev/null | head -1)
    if [ -n "$LATEST_TUNING" ]; then
        INTERMEDIATE_DIR="$LATEST_TUNING/intermediate"
        if [ -d "$INTERMEDIATE_DIR" ]; then
            for tuning_file in "$INTERMEDIATE_DIR"/*.md; do
                if [ -f "$tuning_file" ]; then
                    TUNING_NAME=$(basename "$tuning_file" .md)
                    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
                    
                    # 提取关键信息
                    TUNING_DESC=$(grep -E "瓶颈|Bottleneck|问题" "$tuning_file" | head -1)
                    TUNING_PARAMS=$(grep -E "参数|parameter|sysctl" "$tuning_file" | head -3)
                    TUNING_SCRIPT=$(grep -E "脚本|script|\.sh" "$tuning_file" | head -1)
                    
                    cat >> "$REPORT_FILE" << EOF
| **${TUNING_NAME}场景调优**<br><br>${TUNING_DESC} | **调优方向**:<br>场景化参数优化<br><br>**风险评估**: 低 | **数据来源**:<br>- $tuning_file | ${TUNING_PARAMS} | ${TUNING_SCRIPT}<br><br>**备注**: 参考 $SCENARIO_TUNING_DIR 目录中的调优脚本 | opentunex-scenario-tuning |
EOF
                fi
            done
        fi
    fi
fi

# 从OS级分析结果文件中提取建议
if [ -n "$IO_BOTTLENECK" ]; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **I/O瓶颈**<br><br>${IO_BOTTLENECK} | **调优方向**:<br>参考io_metrics_analysis.txt详细建议<br><br>**风险评估**: 见详细分析 | **数据来源**:<br>- io_metrics_analysis.txt | 参见详细分析文件 | 参见详细分析文件中的执行步骤 | opentunex-io-bottleneck |
EOF
fi

if [ -n "$MEM_BOTTLENECK" ]; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **内存瓶颈**<br><br>${MEM_BOTTLENECK} | **调优方向**:<br>参考memory_metrics_analysis.txt详细建议<br><br>**风险评估**: 见详细分析 | **数据来源**:<br>- memory_metrics_analysis.txt | 参见详细分析文件 | 参见详细分析文件中的执行步骤 | opentunex-mem-bottleneck |
EOF
fi

if [ -n "$NET_BOTTLENECK" ]; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **网络瓶颈**<br><br>${NET_BOTTLENECK} | **调优方向**:<br>参考network_metrics_analysis.txt详细建议<br><br>**风险评估**: 见详细分析 | **数据来源**:<br>- network_metrics_analysis.txt | 参见详细分析文件 | 参见详细分析文件中的执行步骤 | opentunex-net-bottleneck |
EOF
fi

if [ -n "$SCHED_BOTTLENECK" ]; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **调度器瓶颈**<br><br>${SCHED_BOTTLENECK} | **调优方向**:<br>参考scheduler_trace_analysis.txt详细建议<br><br>**风险评估**: 见详细分析 | **数据来源**:<br>- scheduler_trace_analysis.txt | 参见详细分析文件 | 参见详细分析文件中的执行步骤 | opentunex-sched-bottleneck |
EOF
fi

if [ -n "$LOCK_BOTTLENECK" ]; then
    RECOMMENDATION_COUNT=$((RECOMMENDATION_COUNT + 1))
    cat >> "$REPORT_FILE" << EOF
| **锁瓶颈**<br><br>${LOCK_BOTTLENECK} | **调优方向**:<br>参考lock_trace_analysis.txt详细建议<br><br>**风险评估**: 见详细分析 | **数据来源**:<br>- lock_trace_analysis.txt | 参见详细分析文件 | 参见详细分析文件中的执行步骤 | opentunex-lock-bottleneck |
EOF
fi

cat >> "$REPORT_FILE" << EOF

---

## 详细执行步骤

### 1. 参数备份

**执行前必须备份当前配置**:
\`\`\`bash
sysctl -a > /tmp/sysctl_backup_${TIMESTAMP}.conf
cat /proc/meminfo > /tmp/meminfo_backup_${TIMESTAMP}.txt
\`\`\`

### 2. 参数调整验证

**调整后验证参数生效**:
\`\`\`bash
sysctl -a | grep <parameter_name>
\`\`\`

### 3. 性能监控

**调整后持续监控性能指标**:
\`\`\`bash
# CPU监控
mpstat -P ALL 5 10

# I/O监控
iostat -xz 5 10

# 内存监控
vmstat 5 10

# NUMA监控
numastat -p <PID>
\`\`\`

### 4. 参数持久化

**如需持久化，将参数写入配置文件**:
\`\`\`bash
# 写入sysctl.conf
echo "vm.swappiness=10" >> /etc/sysctl.conf
echo "vm.dirty_ratio=10" >> /etc/sysctl.conf
sysctl -p

# 或写入sysctl.d目录
cat > /etc/sysctl.d/99-tuning.conf << 'EOF'
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=5
kernel.sched_migration_cost_ns=1000000
EOF
sysctl --system
\`\`\`

### 5. 回滚方案

**如果出现问题，立即回滚**:
\`\`\`bash
sysctl -p /tmp/sysctl_backup_${TIMESTAMP}.conf
\`\`\`

---

## 安全注意事项

1. **生产环境测试**: 所有参数调整前，应在测试环境验证影响
2. **逐步调整**: 不要一次性调整多个参数，逐步调整并观察效果
3. **监控系统**: 调整后密切监控系统指标变化
4. **回滚方案**: 准备回滚方案，出现问题立即恢复
5. **持久化**: 如需持久化，将参数写入 \`/etc/sysctl.conf\` 或 \`/etc/sysctl.d/\` 目录

---

## 调优建议统计

- 总调优建议数: ${RECOMMENDATION_COUNT}
- 生成时间: $(date +"%Y-%m-%d %H:%M:%S")

---

## 分析完整性检查

- [x] Phase 1: 数据文件检查完成
- [x] Phase 2: 系统环境信息提取完成
- [x] Phase 3: 瓶颈指标分析完成
- [x] Phase 4: 调优建议报告生成完成
- [x] 报告已保存到文件: ${REPORT_FILE}

---

**报告生成完成**
EOF

echo -e "${GREEN}调优建议报告生成完成${NC}"
echo -e "${GREEN}报告文件: $WORKDIR/$REPORT_FILE${NC}"
echo -e "${GREEN}调优建议数: ${RECOMMENDATION_COUNT}${NC}"
echo ""

# 显示报告摘要
echo -e "${BLUE}=== 报告摘要 ===${NC}"
echo ""
head -30 "$REPORT_FILE"

echo ""
echo -e "${YELLOW}提示: 请查阅完整报告文件 $REPORT_FILE 获取详细信息${NC}"
echo -e "${YELLOW}建议: 调整参数前请仔细阅读安全注意事项${NC}"

exit 0