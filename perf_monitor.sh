#!/bin/bash
# perf_monitor.sh - 高性能测试专用监控脚本（低干扰 + 完整日志 + Prometheus 支持）
# 作者：zhangbao
# 用法：./perf_monitor.sh start | stop

# === 配置区 ===
SAMPLE_INTERVAL=2                     # 采样间隔（秒）
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
START_TIME=$(date +%Y%m%d_%H%M%S)     # 记录启动时间
LOG_DIR="/tmp/perf_logs_${START_TIME}" # 强制使用 /tmp，避免 tmpfs 问题
PID_FILE="/tmp/perf_monitor_pids.txt"  # 固定PID文件位置
PROM_FILE="$TEXTFILE_DIR/perf_monitor.prom"
LOG_DIR_FILE="/tmp/perf_monitor_logdir.txt"  # 记录日志目录的文件

# === 初始化 ===
check_tools() {
    for cmd in vmstat iostat mpstat pidstat sar; do
        command -v "$cmd" >/dev/null || {
            echo "❌❌ $cmd 未安装，请运行: yum install -y sysstat"
            exit 1
        }
    done
}

# === 启动监控 ===
start_monitoring() {
    check_tools
    
    # 创建日志目录
    mkdir -p "$TEXTFILE_DIR" "$LOG_DIR" || { echo "❌❌ 无法创建目录"; exit 1; }
    
    # 清空PID文件并记录日志目录
    > "$PID_FILE"
    echo "$LOG_DIR" > "$LOG_DIR_FILE"

    echo "📁📁 日志目录: $LOG_DIR (采样间隔: ${SAMPLE_INTERVAL}s)"

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
    local ACTUAL_LOG_DIR=""

    # 首先尝试读取启动时记录的日志目录
    if [ -f "$LOG_DIR_FILE" ]; then
        ACTUAL_LOG_DIR=$(cat "$LOG_DIR_FILE")
        echo "📁 找到记录的日志目录: $ACTUAL_LOG_DIR"
    else
        # 如果没有记录文件，查找最新的日志目录
        ACTUAL_LOG_DIR=$(find /tmp -maxdepth 1 -name "perf_logs_*" -type d -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -n "$ACTUAL_LOG_DIR" ]; then
            echo "🔍 自动检测到最新日志目录: $ACTUAL_LOG_DIR"
        else
            echo "⚠️  未找到日志目录记录，使用默认路径"
            ACTUAL_LOG_DIR="/tmp/perf_logs_$(date +%Y%m%d_%H%M%S)"
        fi
    fi

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
        # 最简单直接的方法：杀掉所有相关的进程
        pkill vmstat 2>/dev/null && echo "✅ 停止 vmstat 进程"
        pkill iostat 2>/dev/null && echo "✅ 停止 iostat 进程"
        pkill mpstat 2>/dev/null && echo "✅ 停止 mpstat 进程"
        pkill pidstat 2>/dev/null && echo "✅ 停止 pidstat 进程"
        pkill sar 2>/dev/null && echo "✅ 停止 sar 进程"
        pkill -f "perf_monitor.sh start" 2>/dev/null && echo "✅ 停止监控脚本进程"
        
        # 检查是否还有相关进程残留
        if pgrep vmstat >/dev/null || pgrep iostat >/dev/null || pgrep mpstat >/dev/null || pgrep pidstat >/dev/null || pgrep sar >/dev/null; then
            echo "⚠️  仍有进程残留，尝试强制杀死"
            pkill -9 vmstat 2>/dev/null
            pkill -9 iostat 2>/dev/null
            pkill -9 mpstat 2>/dev/null
            pkill -9 pidstat 2>/dev/null
            pkill -9 sar 2>/dev/null
        fi
        
        echo "✅ 所有相关进程已停止"
    fi

    # 清理临时文件
    rm -f "$PROM_FILE" "$LOG_DIR_FILE"
    echo "✅ 监控已停止，指标文件已清理"
    
    # 显示正确的日志目录
    if [ -n "$ACTUAL_LOG_DIR" ] && [ -d "$ACTUAL_LOG_DIR" ]; then
        echo "📝 原始日志仍保留在: $ACTUAL_LOG_DIR （如需保存，请手动备份）"
        echo "📊 日志文件列表:"
        ls -la "$ACTUAL_LOG_DIR"/
    else
        echo "⚠️  日志目录不存在: $ACTUAL_LOG_DIR"
        # 尝试查找任何存在的日志目录
        LATEST_LOG=$(find /tmp -maxdepth 1 -name "perf_logs_*" -type d 2>/dev/null | head -1)
        if [ -n "$LATEST_LOG" ]; then
            echo "🔍 发现其他日志目录: $LATEST_LOG"
            echo "📊 日志文件列表:"
            ls -la "$LATEST_LOG"/
        else
            echo "❌ 未找到任何日志目录"
        fi
    fi
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