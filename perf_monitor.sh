#!/bin/bash
# perf_monitor.sh - 高性能测试专用监控脚本（低干扰 + 完整日志 + Prometheus 支持）
# 作者：zhangbao  
# 用法：./perf_monitor.sh start | stop

# === 配置区 ===
SAMPLE_INTERVAL=2 # 采样间隔（秒）
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# 修复1：使用固定的时间戳，避免启动和停止时时间不一致
START_TIME=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/perf_logs_${START_TIME}"
PID_FILE="/tmp/perf_monitor_pids.txt"
PROM_FILE="$TEXTFILE_DIR/perf_monitor.prom"
LOG_DIR_FILE="/tmp/perf_monitor_logdir.txt"

# === 初始化 ===
check_tools() {
    for cmd in vmstat iostat mpstat pidstat sar; do
        command -v "$cmd" >/dev/null || {
            echo "❌❌❌❌❌❌❌❌ $cmd 未安装，请运行: yum install -y sysstat"
            exit 1
        }
    done
}

# === 启动监控 ===
start_monitoring() {
    check_tools
    
    mkdir -p "$TEXTFILE_DIR" "$LOG_DIR" || {
        echo "❌❌❌❌❌❌❌❌ 无法创建目录"; exit 1;
    }
    
    echo "$LOG_DIR" > "$LOG_DIR_FILE"
    > "$PID_FILE"

    echo "📁📁📁📁📁📁📁📁 日志目录: $LOG_DIR (采样间隔: ${SAMPLE_INTERVAL}s)"

    sleep 1

    # 启动所有监控命令
    echo "🔄🔄 启动监控进程..."
    
    vmstat "$SAMPLE_INTERVAL" > "$LOG_DIR/vmstat.log" 2>&1 &
    VMSTAT_PID=$!
    echo $VMSTAT_PID >> "$PID_FILE"
    echo "✅ vmstat 启动 PID: $VMSTAT_PID"

    iostat -x "$SAMPLE_INTERVAL" > "$LOG_DIR/iostat.log" 2>&1 &
    IOSTAT_PID=$!
    echo $IOSTAT_PID >> "$PID_FILE"
    echo "✅ iostat 启动 PID: $IOSTAT_PID"

    mpstat -P ALL "$SAMPLE_INTERVAL" > "$LOG_DIR/mpstat.log" 2>&1 &
    MPSTAT_PID=$!
    echo $MPSTAT_PID >> "$PID_FILE"
    echo "✅ mpstat 启动 PID: $MPSTAT_PID"

    pidstat -t -u -r -d "$SAMPLE_INTERVAL" > "$LOG_DIR/pidstat.log" 2>&1 &
    PIDSTAT_PID=$!
    echo $PIDSTAT_PID >> "$PID_FILE"
    echo "✅ pidstat 启动 PID: $PIDSTAT_PID"

    sar -n DEV "$SAMPLE_INTERVAL" > "$LOG_DIR/sar_net.log" 2>&1 &
    SAR_PID=$!
    echo $SAR_PID >> "$PID_FILE"
    echo "✅ sar 启动 PID: $SAR_PID"

    sleep 2

    # 检查进程状态
    echo "🔍🔍 检查进程状态:"
    for pid in $VMSTAT_PID $IOSTAT_PID $MPSTAT_PID $PIDSTAT_PID $SAR_PID; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "✅ 进程 $pid 运行正常"
        else
            echo "❌❌ 进程 $pid 已终止"
        fi
    done

    # 启动 Prometheus 更新循环（修复版）
    (
        echo "🔄🔄 启动 Prometheus 指标更新循环..."
        while true; do
            # 检查是否应该退出
            if [ ! -f "$PID_FILE" ]; then
                echo "🔴 检测到停止信号，退出更新循环"
                break
            fi
            
            # --- vmstat 指标 ---
            if [ -s "$LOG_DIR/vmstat.log" ]; then
                vmstat_line=$(tail -n 1 "$LOG_DIR/vmstat.log" 2>/dev/null)
                if [ -n "$vmstat_line" ] && ! echo "$vmstat_line" | grep -q '[a-zA-Z]'; then
                    set -- $vmstat_line
                    io_bi=${9:-0}
                    io_bo=${10:-0}
                else
                    io_bi=0; io_bo=0
                fi
            else
                io_bi=0; io_bo=0
            fi

            # --- iostat 指标 ---
            r_await=0
            w_await=0
            if [ -s "$LOG_DIR/iostat.log" ]; then
                iostat_line=$(grep -vE '(Linux|Device|^$)' "$LOG_DIR/iostat.log" | tail -n 1 2>/dev/null)
                if [ -n "$iostat_line" ] && ! echo "$iostat_line" | grep -q '[a-zA-Z]'; then
                    set -- $iostat_line
                    if [ $# -ge 12 ]; then
                        r_await=${11:-0}
                        w_await=${12:-0}
                    fi
                fi
            fi

            # 安全写入 Prometheus 指标文件
            if mkdir -p "$TEXTFILE_DIR" 2>/dev/null; then
                cat > "$PROM_FILE.tmp" <<EOF
# HELP vmstat_bi_per_second Blocks received from a block device (blocks/s)
# TYPE vmstat_bi_per_second gauge
vmstat_bi_per_second{instance="localhost"} $io_bi

# HELP vmstat_bo_per_second Blocks sent to a block device (blocks/s)
# TYPE vmstat_bo_per_second gauge
vmstat_bo_per_second{instance="localhost"} $io_bo

# HELP disk_r_await Average read I/O wait time (ms)
# TYPE disk_r_await gauge
disk_r_await{instance="localhost"} $r_await

# HELP disk_w_await Average write I/O wait time (ms)
# TYPE disk_w_await gauge
disk_w_await{instance="localhost"} $w_await
EOF
                mv "$PROM_FILE.tmp" "$PROM_FILE" 2>/dev/null || true
            fi
            
            sleep "$SAMPLE_INTERVAL"
        done
    ) &
    PROM_PID=$!
    echo $PROM_PID >> "$PID_FILE"
    echo "✅ Prometheus 更新循环启动 PID: $PROM_PID"

    echo "✅✅✅ 监控已完全启动"
    echo "📊📊 日志目录: $LOG_DIR"
    echo "👉 请运行你的性能测试..."
}

# === 停止监控（修复版）===
stop_monitoring() {
    echo "🛑🛑🛑 开始停止监控..."

    # 读取正确的日志目录
    if [ -f "$LOG_DIR_FILE" ]; then
        ACTUAL_LOG_DIR=$(cat "$LOG_DIR_FILE")
        echo "📁📁 找到记录的日志目录: $ACTUAL_LOG_DIR"
    else
        ACTUAL_LOG_DIR=$(find /tmp -maxdepth 1 -name "perf_logs_*" -type d -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        echo "🔍🔍 自动检测到日志目录: $ACTUAL_LOG_DIR"
    fi

    # 先停止 Prometheus 更新循环（避免文件操作冲突）
    if [ -f "$PID_FILE" ]; then
        # 先发送普通停止信号
        while IFS= read -r pid; do
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null && echo "✅ 发送停止信号到 PID: $pid" || true
            fi
        done < "$PID_FILE"
        
        sleep 1
        
        # 强制终止残留进程
        while IFS= read -r pid; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null && echo "🛑 强制终止 PID: $pid" || true
            fi
        done < "$PID_FILE"
        
        rm -f "$PID_FILE"
    fi

    # 清理所有相关的监控进程
    local monitor_processes=("vmstat" "iostat" "mpstat" "pidstat" "sar")
    for proc in "${monitor_processes[@]}"; do
        pkill -9 -f "$proc $SAMPLE_INTERVAL" 2>/dev/null && echo "✅ 清理 $proc 进程" || true
    done

    # 清理文件
    rm -f "$PROM_FILE" "$LOG_DIR_FILE" "$PROM_FILE.tmp" 2>/dev/null || true
    
    # 显示日志信息
    if [ -d "$ACTUAL_LOG_DIR" ]; then
        echo "📝📝📝📝📝📝📝📝 原始日志保留在: $ACTUAL_LOG_DIR"
        echo "📊📊 日志统计:"
        for logfile in "$ACTUAL_LOG_DIR"/*.log; do
            if [ -f "$logfile" ]; then
                echo "  $(basename "$logfile"): $(wc -l < "$logfile") 行"
            fi
        done
    fi

    echo "✅✅ 监控已完全停止"
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