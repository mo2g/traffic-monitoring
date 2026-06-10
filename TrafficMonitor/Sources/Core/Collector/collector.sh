#!/bin/bash
# ============================================================
# collector.sh — TrafficMonitor root 子进程 (AppleScript 直接以 root 启动)
#
# 由 AppleScript "do shell script" with administrator privileges 启动，
# 无需 sudo，启动后保持 root 直到被杀。
#
# 协议:
#   主进程: touch /tmp/tm_trigger
#   子进程: 检测到 trigger → 删除 → 执行 nettop → 写入 output
#   主进程: 等待 output 文件更新 → 读取 → 继续
# ============================================================

TRIGGER="/tmp/tm_nettop_trigger"
OUTPUT="/tmp/tm_nettop_output"

# 自动检测 nettop
if [ -x "/usr/bin/nettop" ]; then
    NETTOP="/usr/bin/nettop"
elif [ -x "/usr/sbin/nettop" ]; then
    NETTOP="/usr/sbin/nettop"
else
    echo "---ERROR: nettop not found---"
    exit 1
fi

echo "collector: root daemon started (pid $$, nettop=$NETTOP)" >&2

while true; do
    if [ -f "$TRIGGER" ]; then
        rm -f "$TRIGGER"
        "$NETTOP" -l 1 -n -P -J bytes_in,bytes_out,state > "$OUTPUT" 2>/dev/null
        echo "---SNAPSHOT_END---" >> "$OUTPUT"
    fi
    sleep 0.5
done
