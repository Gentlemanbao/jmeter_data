#!/bin/bash
# perf_monitor.sh - 高性能测试专用监控脚本（低干扰 + 完整日志 + Prometheus 支持）
# 作者：zhangbao
# 用法：./perf_monitor.sh start | stop

# === 配置区 ===
SAMPLE_INTERVAL=2                     # 采样间隔（秒）
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
LOG_DIR="/tmp/perf_logs_$(date +%Y%m%d_%H%M%S)"  # 强制使用 /tmp，避免 tmpfs 问题
PID_FILE="$LOG_DIR/pids.txt"
PROM_FILE="$TEXTFILE_DIR/perf_monitor.prom"

# === 初始化 ===
check_tools() {
    for cmd in vmstat iostat mpstat pidstat sar; do
        command -v "$cmd" >/dev/null || {
            echo "❌ $cmd 未安装，请运行: yum install -y sysstat"
            exit 1
        }
    done
}

mkdir -p "$TEXTFILE_DIR" "$LOG_DIR" || { echo "❌ 无法创建目录"; exit 1; }

# === 启动监控 ===
start_monitoring() {
    check_tools
    > "$PID_FILE"

    echo "📁 日志目录: $LOG_DIR (采样间隔: ${SAMPLE_INTERVAL}s)"

    # 启动所有监控命令，并记录 PID
    vmstat "$SAMPLE_INTERVAL" > "$LOG_DIR/vmstat.log" 2>&1 &
    echo $! >> "$PID_FILE"

    iostat -x "$SAMPLE_INTERVAL" > "$LOG_DIR/iostat.log" 2>&1 &
    echo $! >> "$PID_FILE"

    mpstat -P ALL "$SAMPLE_INTERVAL" > "$LOG_DIR/mpstat.log" 2>&1 &
    echo $! >> "$PID_FILE"

    pidstat -t -u -r -d "$SAMPLE_INTERVAL" > "$LOG_DIR/pidstat.log" 2>&1 &
    echo $! >> "$PID_FILE"

    sar -n DEV "$SAMPLE_INTERVAL" > "$LOG_DIR/sar_net.log" 2>&1 &
    echo $! >> "$PID_FILE"

    # 启动 Prometheus 更新循环
    (
        while true; do
            vmstat_line=$(tail -n 1 "$LOG_DIR/vmstat.log")
            if [ -n "$vmstat_line" ]; then
                set -- $vmstat_line
                io_bi=${9:-0}
                io_bo=${10:-0}
            else
                io_bi=0; io_bo=0
            fi

            {
                echo "# HELP vmstat_bi_per_second Blocks received from a block device (blocks/s)"
                echo "# TYPE vmstat_bi_per_second gauge"
                echo "vmstat_bi_per_second{instance=\"localhost\"} $io_bi"

                echo "# HELP vmstat_bo_per_second Blocks sent to a block device (blocks/s)"
                echo "# TYPE vmstat_bo_per_second gauge"
                echo "vmstat_bo_per_second{instance=\"localhost\"} $io_bo"
            } > "$PROM_FILE.tmp"

            mv "$PROM_FILE.tmp" "$PROM_FILE"
            sleep "$SAMPLE_INTERVAL"
        done
    ) &
    echo $! >> "$PID_FILE"

    echo "✅ 监控已启动，原始日志保留，Prometheus 指标就绪"
    echo "👉 请运行你的性能测试..."
}

# === 停止监控（增强版）===
stop_monitoring() {
    local found=false

    # 方法1：尝试从 pids.txt 获取 PID 并 kill
    if [ -f "$PID_FILE" ]; then
        echo "🔄 正在尝试从 PID 文件停止进程..."
        while IFS= read -r pid; do
            if kill "$pid" 2>/dev/null; then
                echo "✅ 停止进程 PID: $pid"
                found=true
            else
                echo "⚠️  进程 PID: $pid 已终止或不存在"
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi

    # 方法2：如果没找到，尝试通过进程名杀掉
    if [ "$found" = false ]; then
        echo "🔍 未找到 PID 文件，正在搜索相关进程..."
        pids=$(pgrep -f "perf_monitor\.sh\|vmstat\|iostat\|mpstat\|pidstat\|sar")
        if [ -n "$pids" ]; then
            echo "🛑 正在强制停止所有相关进程..."
            kill $pids 2>/dev/null
            echo "✅ 所有相关进程已停止"
        else
            echo "❌ 未找到任何相关进程"
            return 1
        fi
    fi

    # 清理 Prometheus 文件
    rm -f "$PROM_FILE"
    echo "✅ 监控已停止，指标文件已清理"
    echo "📝 原始日志仍保留在: $LOG_DIR （如需保存，请手动备份）"
}

# === 主逻辑 ===
case "$1" in
    start)
        start_monitoring
        ;;
    stop)
        stop_monitoring
        ;;
    *)
        echo "用法: $0 {start|stop}"
        exit 1
        ;;
esac