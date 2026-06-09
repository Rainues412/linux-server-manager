#!/bin/bash
###############################################################################
#  Linux 服务器一键负载诊断脚本
#  用法: bash server_diag.sh
#  兼容: CentOS / Ubuntu / Debian 等主流发行版
#  无需安装额外依赖，缺失工具会给出提示
###############################################################################

# ========================== 颜色定义 ==========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ========================== 工具函数 ==========================

# 打印分隔线
separator() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

# 打印模块标题
section_title() {
    separator
    echo -e "${BOLD}  [$1] $2${NC}"
    separator
}

# 警告输出
warn() {
    echo -e "  ${YELLOW}⚠ $1${NC}"
}

# 危险输出
danger() {
    echo -e "  ${RED}✘ $1${NC}"
}

# 正常输出
info() {
    echo -e "  ${GREEN}✔ $1${NC}"
}

# 检查命令是否存在
cmd_exists() {
    command -v "$1" &>/dev/null
}

# ========================== 收集结果（用于最终汇总）==========================
declare -a SUMMARY_LINES

add_summary() {
    # $1=状态(ok/warn/danger) $2=维度名 $3=描述
    case "$1" in
        ok)     SUMMARY_LINES+=("${GREEN}✔ 正常${NC}  | $2 | $3") ;;
        warn)   SUMMARY_LINES+=("${YELLOW}⚠ 警告${NC}  | $2 | $3") ;;
        danger) SUMMARY_LINES+=("${RED}✘ 异常${NC}  | $2 | $3") ;;
    esac
}

# ========================== 基本信息 ==========================
section_title "0" "服务器基本信息"

echo "  主机名      : $(hostname 2>/dev/null || echo 'N/A')"
echo "  内核版本    : $(uname -r)"
echo "  系统版本    : $(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 | tr -d '"' || echo 'N/A')"
echo "  CPU 型号    : $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo 'N/A')"
CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)
echo "  CPU 核心数  : ${CPU_CORES}"
echo "  运行时间    : $(uptime -p 2>/dev/null || uptime)"
echo "  当前时间    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  当前登录用户: $(who 2>/dev/null | wc -l) 个"
who 2>/dev/null | awk '{print "                "$0}'

# ========================== 1. CPU 负载 ==========================
section_title "1" "CPU 负载分析"

# -- 1.1 Load Average --
echo ""
echo -e "  ${BOLD}[1.1] Load Average${NC}"
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)
LOAD_1=$(echo "$LOAD_AVG" | awk -F',' '{print $1}' | xargs)
LOAD_5=$(echo "$LOAD_AVG" | awk -F',' '{print $2}' | xargs)
LOAD_15=$(echo "$LOAD_AVG" | awk -F',' '{print $3}' | xargs)
echo "  1分钟: ${LOAD_1}  |  5分钟: ${LOAD_5}  |  15分钟: ${LOAD_15}"
echo "  CPU核心数: ${CPU_CORES}"

# 判断负载
if [ "$CPU_CORES" -gt 0 ] 2>/dev/null; then
    OVERLOADED=$(awk "BEGIN {print ($LOAD_1 > $CPU_CORES) ? 1 : 0}")
    TREND_UP=$(awk "BEGIN {print ($LOAD_1 > $LOAD_15 * 1.5) ? 1 : 0}")
    if [ "$OVERLOADED" -eq 1 ]; then
        danger "1分钟负载 (${LOAD_1}) > CPU核心数 (${CPU_CORES})，当前过载！"
        add_summary "danger" "CPU负载" "负载 ${LOAD_1} 超过核心数 ${CPU_CORES}"
    elif [ "$TREND_UP" -eq 1 ]; then
        warn "负载呈上升趋势 (${LOAD_15} → ${LOAD_1})，需持续关注"
        add_summary "warn" "CPU负载" "负载上升趋势 ${LOAD_15}→${LOAD_1}"
    else
        info "负载正常，1min=${LOAD_1} / 核心数=${CPU_CORES}"
        add_summary "ok" "CPU负载" "负载 ${LOAD_1}，核心数 ${CPU_CORES}"
    fi
fi

# -- 1.2 CPU 使用率概况 --
echo ""
echo -e "  ${BOLD}[1.2] CPU 使用率概况 (采样1秒)${NC}"
if cmd_exists mpstat; then
    mpstat 1 1 | tail -1 | awk '{
        printf "  用户态(us): %.1f%%  |  内核态(sy): %.1f%%  |  IO等待(wa): %.1f%%  |  空闲(id): %.1f%%\n", $3, $5, $6, $12
    }'
else
    # 用 /proc/stat 手动计算
    read cpu user nice system idle iowait irq softirq steal guest guest_nice < <(head -1 /proc/stat)
    sleep 1
    read cpu user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 < <(head -1 /proc/stat)
    total=$(( (user2+nice2+system2+idle2+iowait2+irq2+softirq2+steal2) - (user+nice+system+idle+iowait+irq+softirq+steal) ))
    if [ "$total" -gt 0 ]; then
        idle_diff=$(( idle2 - idle ))
        iowait_diff=$(( iowait2 - iowait ))
        idle_pct=$(awk "BEGIN {printf \"%.1f\", $idle_diff/$total*100}")
        iowait_pct=$(awk "BEGIN {printf \"%.1f\", $iowait_diff/$total*100}")
        used_pct=$(awk "BEGIN {printf \"%.1f\", 100-$idle_diff/$total*100}")
        echo "  总使用率: ${used_pct}%  |  IO等待: ${iowait_pct}%  |  空闲: ${idle_pct}%"
    fi
    warn "建议安装 sysstat 以获得更详细的 mpstat 数据"
fi

# -- 1.3 CPU 占用 Top 5 进程 --
echo ""
echo -e "  ${BOLD}[1.3] CPU 占用 Top 5 进程${NC}"
printf "  ${BOLD}%-8s %-6s %-6s %s${NC}\n" "PID" "%CPU" "%MEM" "COMMAND"
ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=6 {printf "  %-8s %-6s %-6s %s\n", $2, $3, $4, $11}'

# ========================== 2. 内存分析 ==========================
section_title "2" "内存分析"

# -- 2.1 内存使用概况 --
echo ""
echo -e "  ${BOLD}[2.1] 内存使用概况${NC}"
free -h 2>/dev/null

echo ""
# 解析具体数值 (单位 kB)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
MEM_BUFFERS=$(grep Buffers /proc/meminfo | awk '{print $2}')
MEM_CACHED=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{print $2}')

if [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null; then
    MEM_USED_PCT=$(awk "BEGIN {printf \"%.1f\", (1 - $MEM_AVAIL/$MEM_TOTAL) * 100}")
    MEM_AVAIL_MB=$(awk "BEGIN {printf \"%.0f\", $MEM_AVAIL/1024}")
    MEM_TOTAL_MB=$(awk "BEGIN {printf \"%.0f\", $MEM_TOTAL/1024}")
    echo "  实际使用率: ${MEM_USED_PCT}% (基于 Available 计算)"
    echo "  可用内存: ${MEM_AVAIL_MB} MB / 总计: ${MEM_TOTAL_MB} MB"

    USED_HIGH=$(awk "BEGIN {print ($MEM_AVAIL/$MEM_TOTAL < 0.1) ? 1 : 0}")
    USED_WARN=$(awk "BEGIN {print ($MEM_AVAIL/$MEM_TOTAL < 0.2) ? 1 : 0}")
    if [ "$USED_HIGH" -eq 1 ]; then
        danger "可用内存不足 10%！仅剩 ${MEM_AVAIL_MB}MB"
        add_summary "danger" "内存" "可用仅 ${MEM_AVAIL_MB}MB (${MEM_USED_PCT}% 已用)"
    elif [ "$USED_WARN" -eq 1 ]; then
        warn "可用内存不足 20%，剩余 ${MEM_AVAIL_MB}MB"
        add_summary "warn" "内存" "可用 ${MEM_AVAIL_MB}MB (${MEM_USED_PCT}% 已用)"
    else
        info "内存充足，可用 ${MEM_AVAIL_MB}MB"
        add_summary "ok" "内存" "可用 ${MEM_AVAIL_MB}MB (${MEM_USED_PCT}% 已用)"
    fi
fi

# -- 2.2 Swap 使用 --
echo ""
echo -e "  ${BOLD}[2.2] Swap 使用情况${NC}"
if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
    SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
    SWAP_USED_PCT=$(awk "BEGIN {printf \"%.1f\", $SWAP_USED/$SWAP_TOTAL*100}")
    SWAP_USED_MB=$(awk "BEGIN {printf \"%.0f\", $SWAP_USED/1024}")
    SWAP_TOTAL_MB=$(awk "BEGIN {printf \"%.0f\", $SWAP_TOTAL/1024}")
    echo "  Swap 已用: ${SWAP_USED_MB}MB / 总计: ${SWAP_TOTAL_MB}MB (${SWAP_USED_PCT}%)"

    SWAP_HIGH=$(awk "BEGIN {print ($SWAP_USED/$SWAP_TOTAL > 0.5) ? 1 : 0}")
    if [ "$SWAP_HIGH" -eq 1 ]; then
        danger "Swap 使用超过 50%，内存可能严重不足"
        add_summary "danger" "Swap" "已用 ${SWAP_USED_PCT}%"
    elif [ "$SWAP_USED" -gt 0 ]; then
        warn "Swap 有使用 (${SWAP_USED_MB}MB)，关注是否持续增长"
        add_summary "warn" "Swap" "已用 ${SWAP_USED_MB}MB (${SWAP_USED_PCT}%)"
    else
        info "Swap 未使用"
        add_summary "ok" "Swap" "未使用"
    fi
else
    info "未配置 Swap 或 Swap 为 0"
    add_summary "ok" "Swap" "未配置"
fi

# -- 2.3 内存占用 Top 5 进程 --
echo ""
echo -e "  ${BOLD}[2.3] 内存占用 Top 5 进程${NC}"
printf "  ${BOLD}%-8s %-6s %-10s %s${NC}\n" "PID" "%MEM" "RSS(MB)" "COMMAND"
ps aux --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=6 {printf "  %-8s %-6s %-10.1f %s\n", $2, $4, $6/1024, $11}'

# ========================== 3. 磁盘 IO ==========================
section_title "3" "磁盘 IO 分析"

# -- 3.1 iostat --
echo ""
echo -e "  ${BOLD}[3.1] 磁盘 IO 统计 (采样1秒)${NC}"
if cmd_exists iostat; then
    iostat -xz 1 2 2>/dev/null | awk '
        /^Device/ { found=1 }
        found && /^$/ { exit }
        found { print "  "$0 }
    '
    # 检查是否有磁盘饱和
    UTIL_HIGH=$(iostat -xz 1 2 2>/dev/null | awk '/^Device/{found=1} found && $NF > 90 {print $1; exit}')
    if [ -n "$UTIL_HIGH" ]; then
        danger "磁盘 ${UTIL_HIGH} 使用率接近 100%，IO 饱和！"
        add_summary "danger" "磁盘IO" "${UTIL_HIGH} 接近饱和"
    else
        info "磁盘 IO 正常，无饱和现象"
        add_summary "ok" "磁盘IO" "无饱和现象"
    fi
else
    warn "未安装 sysstat，无法使用 iostat"
    echo "  安装方法: yum install -y sysstat  或  apt install -y sysstat"
    # 降级：读 /proc/diskstats
    echo ""
    echo "  降级方案 - /proc/diskstats 原始数据:"
    awk '$3 !~ /^(loop|ram)/ {printf "  %-12s 读: %s 次  写: %s 次\n", $3, $4, $8}' /proc/diskstats 2>/dev/null
    add_summary "warn" "磁盘IO" "缺少 iostat，建议安装 sysstat"
fi

# -- 3.2 IO 占用 Top 进程 --
echo ""
echo -e "  ${BOLD}[3.2] 当前 IO 活跃进程 (需 root)${NC}"
if cmd_exists iotop; then
    iotop -b -n 1 -o 2>/dev/null | head -15 | awk '{print "  "$0}'
elif [ -d /proc ]; then
    echo "  (iotop 不可用，展示 /proc 中 IO 最高的 5 个进程)"
    printf "  ${BOLD}%-8s %-12s %-12s %s${NC}\n" "PID" "读(kB)" "写(kB)" "COMMAND"
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | head -50); do
        if [ -r "/proc/$pid/io" ]; then
            read_bytes=$(grep read_bytes /proc/$pid/io 2>/dev/null | awk '{print $2}')
            write_bytes=$(grep write_bytes /proc/$pid/io 2>/dev/null | awk '{print $2}')
            cmd=$(cat /proc/$pid/comm 2>/dev/null)
            echo "$pid ${read_bytes:-0} ${write_bytes:-0} $cmd"
        fi
    done 2>/dev/null | sort -k2 -rn | head -5 | awk '{printf "  %-8s %-12.1f %-12.1f %s\n", $1, $2/1024, $3/1024, $4}'
else
    warn "iotop 不可用"
fi

# ========================== 4. 网络分析 ==========================
section_title "4" "网络分析"

# -- 4.1 连接数统计 --
echo ""
echo -e "  ${BOLD}[4.1] TCP 连接状态统计${NC}"
if cmd_exists ss; then
    ss -ant 2>/dev/null | awk 'NR>1 {state[$1]++} END {
        for (s in state) printf "  %-16s : %d\n", s, state[s]
    }' | sort -t: -k2 -rn

    TOTAL_CONN=$(ss -ant 2>/dev/null | tail -n +2 | wc -l)
    ESTABLISHED=$(ss -ant state established 2>/dev/null | tail -n +2 | wc -l)
    TIME_WAIT=$(ss -ant state time-wait 2>/dev/null | tail -n +2 | wc -l)

    echo ""
    echo "  总连接数: ${TOTAL_CONN}  |  ESTABLISHED: ${ESTABLISHED}  |  TIME_WAIT: ${TIME_WAIT}"

    if [ "$TIME_WAIT" -gt 10000 ] 2>/dev/null; then
        danger "TIME_WAIT 连接数过多 (${TIME_WAIT})，可能需要内核调优"
        add_summary "danger" "网络" "TIME_WAIT ${TIME_WAIT} 个"
    elif [ "$ESTABLISHED" -gt 5000 ] 2>/dev/null; then
        warn "ESTABLISHED 连接较多 (${ESTABLISHED})，关注是否正常"
        add_summary "warn" "网络" "ESTABLISHED ${ESTABLISHED} 个"
    else
        info "TCP 连接状态正常"
        add_summary "ok" "网络" "总连接 ${TOTAL_CONN}，状态正常"
    fi
else
    warn "ss 命令不可用"
    add_summary "warn" "网络" "ss 不可用"
fi

# -- 4.2 监听端口 --
echo ""
echo -e "  ${BOLD}[4.2] 当前监听端口${NC}"
if cmd_exists ss; then
    ss -tlnp 2>/dev/null | awk 'NR>1 {printf "  %-24s  %-24s  %s\n", $4, $6, $7}' | head -20
    LISTEN_COUNT=$(ss -tlnp 2>/dev/null | tail -n +2 | wc -l)
    echo "  共 ${LISTEN_COUNT} 个监听端口"
elif cmd_exists netstat; then
    netstat -tlnp 2>/dev/null | awk '/^tcp/ {printf "  %-24s  %s\n", $4, $7}' | head -20
else
    warn "ss/netstat 均不可用"
fi

# -- 4.3 网络流量 --
echo ""
echo -e "  ${BOLD}[4.3] 网卡流量 (采样2秒)${NC}"
if cmd_exists sar; then
    sar -n DEV 1 2 2>/dev/null | awk '/Average/ && $2 != "IFACE" && $2 != "lo" {
        printf "  %-12s 接收: %.2f kB/s  发送: %.2f kB/s\n", $2, $5, $6
    }'
else
    # 降级方案：读 /proc/net/dev
    echo "  (sar 不可用，展示网卡累计流量)"
    awk 'NR>2 && $1 !~ /lo:/ {
        gsub(":", "", $1);
        printf "  %-12s 接收: %.1f MB  发送: %.1f MB\n", $1, $2/1048576, $10/1048576
    }' /proc/net/dev 2>/dev/null
    warn "安装 sysstat 可获取实时速率"
fi

# ========================== 5. 磁盘空间 ==========================
section_title "5" "磁盘空间分析"

# -- 5.1 分区使用率 --
echo ""
echo -e "  ${BOLD}[5.1] 磁盘分区使用率${NC}"
df -hP 2>/dev/null | head -1 | awk '{print "  "$0}'
df -hP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|Filesystem)' | awk '{print "  "$0}'

echo ""
# 检查高使用率分区
DISK_WARN=""
DISK_DANGER=""
while IFS= read -r line; do
    pct=$(echo "$line" | awk '{gsub(/%/,""); print $(NF-1)}')
    mount=$(echo "$line" | awk '{print $NF}')
    if [ "$pct" -ge 95 ] 2>/dev/null; then
        DISK_DANGER="${DISK_DANGER} ${mount}(${pct}%)"
    elif [ "$pct" -ge 85 ] 2>/dev/null; then
        DISK_WARN="${DISK_WARN} ${mount}(${pct}%)"
    fi
done < <(df -hP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|Filesystem)')

if [ -n "$DISK_DANGER" ]; then
    danger "以下分区使用率 ≥95%:${DISK_DANGER}"
    add_summary "danger" "磁盘空间" "分区即将满载:${DISK_DANGER}"
elif [ -n "$DISK_WARN" ]; then
    warn "以下分区使用率 ≥85%:${DISK_WARN}"
    add_summary "warn" "磁盘空间" "使用率偏高:${DISK_WARN}"
else
    info "所有分区使用率正常 (<85%)"
    add_summary "ok" "磁盘空间" "所有分区使用率 <85%"
fi

# -- 5.2 Inode 使用率 --
echo ""
echo -e "  ${BOLD}[5.2] Inode 使用率${NC}"
df -iP 2>/dev/null | head -1 | awk '{print "  "$0}'
df -iP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|Filesystem)' | awk '{print "  "$0}'

echo ""
INODE_WARN=$(df -iP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|Filesystem)' | awk '{gsub(/%/,"",$5); if($5+0 > 80) print $NF"("$5"%)"}')
if [ -n "$INODE_WARN" ]; then
    danger "Inode 使用率过高: ${INODE_WARN}"
    add_summary "danger" "Inode" "使用率过高: ${INODE_WARN}"
else
    info "Inode 使用率正常"
    add_summary "ok" "Inode" "使用率正常"
fi

# -- 5.3 空间占用 Top 目录 --
echo ""
echo -e "  ${BOLD}[5.3] 根目录空间占用 Top 10 (超时 120s)${NC}"
du_result=$(timeout 120 bash -c 'du -sh /* 2>/dev/null | sort -rh | head -10' 2>&1)
du_exit=$?
if [ $du_exit -eq 124 ]; then
    warn "du 扫描超过 120s，已终止进程，跳过 Top 10 目录统计"
    warn "建议手动执行: du -sh /* | sort -rh | head -10"
    add_summary "warn" "磁盘空间" "du 扫描超时(120s)，跳过 Top 10"
else
    echo "$du_result" | awk '{printf "  %-12s %s\n", $1, $2}'
fi

# ========================== 6. 进程与系统 ==========================
section_title "6" "进程与系统状态"

# -- 6.1 进程总数 --
echo ""
echo -e "  ${BOLD}[6.1] 进程概况${NC}"
PROC_TOTAL=$(ps aux 2>/dev/null | wc -l)
PROC_ZOMBIE=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count+0}')
echo "  进程总数: ${PROC_TOTAL}  |  僵尸进程: ${PROC_ZOMBIE}"

if [ "$PROC_ZOMBIE" -gt 0 ] 2>/dev/null; then
    warn "存在 ${PROC_ZOMBIE} 个僵尸进程"
    echo "  僵尸进程列表:"
    ps aux 2>/dev/null | awk '$8 ~ /Z/ {printf "    PID=%-8s PPID=%-8s %s\n", $2, $3, $11}'
    add_summary "warn" "进程" "存在 ${PROC_ZOMBIE} 个僵尸进程"
else
    info "无僵尸进程"
    add_summary "ok" "进程" "无僵尸进程"
fi

# -- 6.2 文件描述符 --
echo ""
echo -e "  ${BOLD}[6.2] 文件描述符使用${NC}"
if [ -f /proc/sys/fs/file-nr ]; then
    read fd_allocated fd_free fd_max < /proc/sys/fs/file-nr
    fd_pct=$(awk "BEGIN {printf \"%.1f\", $fd_allocated/$fd_max*100}")
    echo "  已分配: ${fd_allocated}  |  最大限制: ${fd_max}  |  使用率: ${fd_pct}%"

    FD_HIGH=$(awk "BEGIN {print ($fd_allocated/$fd_max > 0.8) ? 1 : 0}")
    if [ "$FD_HIGH" -eq 1 ]; then
        danger "文件描述符使用率超过 80%！"
        add_summary "danger" "文件描述符" "使用率 ${fd_pct}%"
    else
        info "文件描述符使用率正常 (${fd_pct}%)"
        add_summary "ok" "文件描述符" "使用率 ${fd_pct}%"
    fi
fi

# -- 6.3 内核错误日志 --
echo ""
echo -e "  ${BOLD}[6.3] 近期内核关键日志 (dmesg)${NC}"
OOM_COUNT=$(dmesg 2>/dev/null | grep -ci "out of memory\|oom-killer")
if [ "$OOM_COUNT" -gt 0 ] 2>/dev/null; then
    danger "检测到 OOM Killer 记录 (${OOM_COUNT} 次)！"
    dmesg 2>/dev/null | grep -i "oom-killer\|out of memory" | tail -5 | awk '{print "  "$0}'
    add_summary "danger" "内核日志" "OOM Killer 触发 ${OOM_COUNT} 次"
else
    info "无 OOM Killer 记录"
fi

# 硬件错误
HW_ERRORS=$(dmesg 2>/dev/null | grep -ciE "hardware error|machine check|mce:")
if [ "$HW_ERRORS" -gt 0 ] 2>/dev/null; then
    warn "检测到硬件错误日志 (${HW_ERRORS} 条)"
    dmesg 2>/dev/null | grep -iE "hardware error|machine check|mce:" | tail -3 | awk '{print "  "$0}'
    add_summary "warn" "内核日志" "硬件错误 ${HW_ERRORS} 条"
fi

# 显示最近 10 条 dmesg
echo ""
echo "  最近 10 条内核日志:"
dmesg --time-format iso 2>/dev/null | tail -10 | awk '{print "  "$0}' || \
dmesg 2>/dev/null | tail -10 | awk '{print "  "$0}'

# -- 6.4 最近登录 --
echo ""
echo -e "  ${BOLD}[6.4] 最近 5 次登录记录${NC}"
if cmd_exists last; then
    last -5 2>/dev/null | head -5 | awk '{print "  "$0}'
fi

FAILED_LOGIN=$(lastb 2>/dev/null | wc -l)
if [ "$FAILED_LOGIN" -gt 1000 ] 2>/dev/null; then
    warn "登录失败记录达 ${FAILED_LOGIN} 次，可能遭受暴力攻击"
    add_summary "warn" "安全" "登录失败 ${FAILED_LOGIN} 次"
elif cmd_exists lastb; then
    info "登录失败记录: ${FAILED_LOGIN} 次"
fi

# ========================== 最终汇总报告 ==========================
separator
separator
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║              📊  诊 断 结 果 汇 总  📊                 ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}状态    | 维度         | 说明${NC}"
echo "  --------+--------------+--------------------------------------"

for line in "${SUMMARY_LINES[@]}"; do
    echo -e "  $line"
done

separator

# 统计异常数
DANGER_COUNT=0
WARN_COUNT=0
for line in "${SUMMARY_LINES[@]}"; do
    if echo -e "$line" | grep -q "✘"; then
        ((DANGER_COUNT++))
    elif echo -e "$line" | grep -q "⚠"; then
        ((WARN_COUNT++))
    fi
done

echo ""
if [ "$DANGER_COUNT" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}🔴 发现 ${DANGER_COUNT} 个异常项，${WARN_COUNT} 个警告项，建议立即排查！${NC}"
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}🟡 发现 ${WARN_COUNT} 个警告项，建议持续关注。${NC}"
else
    echo -e "  ${GREEN}${BOLD}🟢 所有维度检查通过，服务器状态健康！${NC}"
fi

echo ""
echo -e "  诊断完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
separator
echo ""
