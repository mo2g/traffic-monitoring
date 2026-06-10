#!/bin/bash
# ============================================================
# build_and_test.sh — TrafficMonitor Phase 0 编译与测试
#
# 用法:
#   cd TrafficMonitor
#   bash build_and_test.sh
#
# 要求:
#   - macOS 14+ (Sonoma)
#   - Xcode 16+ (Swift 6.0 toolchain)
#   - 或 Swift 6.0 CLI (swift.org)
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TrafficMonitor Phase 0 — 编译与测试                     ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── 检查环境 ──

if ! command -v swift &> /dev/null; then
    echo ""
    echo "❌ swift 未找到。请安装 Xcode 16+ 或 Swift 6.0 工具链"
    echo "   https://www.swift.org/download/"
    exit 1
fi

SWIFT_VERSION=$(swift --version | head -1)
echo ""
echo "Swift: $SWIFT_VERSION"

# ── 解析依赖 ──

echo ""
echo "── 解析依赖 ──"
swift package resolve 2>&1 | tail -5
echo "   ✓ 完成"

# ── 编译 ──

echo ""
echo "── 编译 TrafficMonitor ──"
if swift build 2>&1; then
    echo "   ✓ 编译通过"
else
    echo "   ❌ 编译失败"
    exit 1
fi

# ── 测试 ──

echo ""
echo "── 运行测试 ──"
if swift test 2>&1; then
    echo "   ✓ 全部测试通过"
else
    echo "   ❌ 测试失败"
    exit 1
fi

# ── 输出产物 ──

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Phase 0 编译 & 测试全部通过 ✓"
echo ""
echo "  产物: .build/debug/TrafficMonitor"
echo ""
echo "  手动运行采集器测试（需要 sudo）:"
echo "    sudo .build/debug/TrafficMonitor"
echo ""
echo "  或先从终端测试子进程脚本:"
echo "    echo go | sudo bash Sources/Core/Collector/collector.sh"
echo "════════════════════════════════════════════════════════════"
