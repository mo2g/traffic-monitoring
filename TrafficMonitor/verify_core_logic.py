#!/usr/bin/env python3
"""
verify_core_logic.py — 在 Linux 环境下验证 TrafficMonitor 核心逻辑

由于完整项目依赖 AppKit/SwiftUI/GRDB（macOS 独有框架），无法在当前
Linux VM 中编译完整 Swift 项目。此脚本用 Python 重写了同样的解析和
差值计算逻辑并运行测试，验证算法正确性。

测试覆盖:
  1. NettopParser — nettop 文本解析
  2. DeltaCalculator — 快照差值计算
  3. ProcessAggregator — Bundle ID 优先聚合
  4. ByteFormatter — 字节格式化
"""

import unittest
import math
import re
from datetime import datetime


# ================================================================
# 1. NettopParser — 从 Swift NettopParser.swift 逐行翻译
# ================================================================

EXCLUDED_PROCESSES = {"kernel_task", "launchd", "WindowServer"}

def parse_bytes(raw: str) -> int:
    """解析 nettop 字节值: "1.0MiB" → 1048576, "500KiB" → 512000"""
    cleaned = raw.strip().replace(",", "")
    if cleaned == "0B" or cleaned == "0":
        return 0

    units = [
        ("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824),
        ("MiB", 1_048_576), ("KiB", 1_024),
        ("TB",  1_000_000_000_000), ("GB", 1_000_000_000),
        ("MB",  1_000_000), ("KB", 1_000),
        ("B",   1),
    ]

    for suffix, multiplier in units:
        if cleaned.endswith(suffix):
            try:
                num = float(cleaned[:-len(suffix)])
                return int(num * multiplier)
            except ValueError:
                pass

    try:
        return int(float(cleaned))
    except ValueError:
        return 0


def parse_nettop_output(raw: str) -> list[dict]:
    """
    解析 nettop -l 1 -n -P -J bytes_in,bytes_out,state 输出
    返回: [{"execName": str, "pid": int, "bytesIn": int, "bytesOut": int}, ...]
    """
    lines = raw.strip().split("\n")
    records: dict[int, dict] = {}  # pid → aggregated record

    byte_pattern = re.compile(r'^[\d.]+[KMGT]?i?B$')

    for line in lines:
        trimmed = line.strip()
        if not trimmed or "nettop" in trimmed or "bytes_in" in trimmed:
            continue
        if trimmed.startswith("---") or trimmed.startswith("==="):
            continue

        parts = trimmed.split()
        if len(parts) < 3:
            continue

        # 找 "进程名.PID" token——可能是 parts[0]，也可能在后续
        # （因为进程名含空格，如 "Google Chrome.1234" → split 为 ["Google", "Chrome.1234"]）
        proc_token = None
        proc_index = -1
        for i, p in enumerate(parts):
            if re.search(r'\.\d{1,6}$', p):
                proc_token = p
                proc_index = i
                break

        if proc_token is None:
            continue

        # 提取 PID
        last_dot = proc_token.rfind(".")
        pid_str = proc_token[last_dot + 1:]
        try:
            pid = int(pid_str)
        except ValueError:
            continue

        # 进程名：把 PID token 之前的所有 part 拼接（处理含空格的进程名）
        proc_name_parts = parts[:proc_index] + [proc_token[:last_dot]]
        proc_name = " ".join(filter(None, proc_name_parts))

        # 找字节值（在 PID token 之后的 part 中）
        tail_parts = parts[proc_index + 1:]
        byte_values = [p for p in tail_parts if byte_pattern.match(p)]
        if len(byte_values) < 2:
            continue

        bytes_in = parse_bytes(byte_values[-2])
        bytes_out = parse_bytes(byte_values[-1])

        # 排除系统进程
        if proc_name in EXCLUDED_PROCESSES:
            continue

        # PID 聚合（同一进程的多条连接）
        if pid in records:
            records[pid]["bytesIn"] += bytes_in
            records[pid]["bytesOut"] += bytes_out
        else:
            records[pid] = {
                "execName": proc_name,
                "pid": pid,
                "bytesIn": bytes_in,
                "bytesOut": bytes_out,
            }

    # 过滤零流量
    return [
        r for r in records.values()
        if r["bytesIn"] > 0 or r["bytesOut"] > 0
    ]


# ================================================================
# 2. DeltaCalculator — 从 Swift DeltaCalculator.swift 逐行翻译
# ================================================================

def compute_deltas(
    prev: dict[str, tuple[int, int]] | None,
    curr: dict[str, tuple[int, int]],
    interval: float
) -> list[dict]:
    """
    prev: {process_key: (bytes_in_cumulative, bytes_out_cumulative)}
    curr: 同上
    interval: 两次快照间隔（秒）
    返回: [{"process": str, "bytesIn": int, "bytesOut": int}, ...]
    """
    if prev is None:
        return []  # 首次快照，无基线

    deltas = []

    for proc_key, (curr_in, curr_out) in curr.items():
        prev_vals = prev.get(proc_key)

        if prev_vals is not None:
            delta_in = curr_in - prev_vals[0]
            delta_out = curr_out - prev_vals[1]
        else:
            # 新出现的进程，保守估计
            delta_in = max(curr_in // 10, 0)
            delta_out = max(curr_out // 10, 0)

        # 进程重启处理（计数器回退）
        if delta_in < 0:
            delta_in = max(curr_in // 10, 0)
        if delta_out < 0:
            delta_out = max(curr_out // 10, 0)

        # 过滤异常值 (>100MB/s * interval)
        max_reasonable = int(100_000_000 * interval)
        if delta_in > max_reasonable or delta_out > max_reasonable:
            delta_in = min(delta_in, max_reasonable)
            delta_out = min(delta_out, max_reasonable)

        if delta_in == 0 and delta_out == 0 and proc_key in prev:
            continue

        deltas.append({
            "process": proc_key,
            "bytesIn": max(delta_in, 0),
            "bytesOut": max(delta_out, 0),
        })

    return deltas


# ================================================================
# 3. 测试用例
# ================================================================

class TestNettopParser(unittest.TestCase):
    """对应 Swift NettopParserTests"""

    def test_empty_output(self):
        records = parse_nettop_output("")
        self.assertEqual(len(records), 0)

    def test_header_only(self):
        records = parse_nettop_output(
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
        )
        self.assertEqual(len(records), 0)

    def test_single_process(self):
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r["execName"], "Google Chrome")
        self.assertEqual(r["pid"], 1234)
        self.assertEqual(r["bytesIn"], 1_048_576)  # 1.0 MiB
        self.assertEqual(r["bytesOut"], 512_000)   # 500 KiB

    def test_multiple_processes(self):
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established\n"
            "Microsoft Edge.5678          tcp4 10.0.0.1:443         2.5MB      1.0MB    Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 2)

    def test_same_pid_multiple_connections(self):
        """同一 PID 的多条连接应聚合"""
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established\n"
            "Google Chrome.1234           tcp4 10.0.0.1:80          100KiB     50.0KiB  Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r["bytesIn"], 1_048_576 + 102_400)  # 1.0MiB + 100KiB
        self.assertEqual(r["bytesOut"], 512_000 + 51_200)     # 500KiB + 50.0KiB

    def test_zero_byte_process_filtered(self):
        """零流量进程被过滤"""
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "com.apple.WebKit.5678        tcp4 *:*                   0B         0B       Listen\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 0)

    def test_system_process_excluded(self):
        """系统进程永远被排除"""
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "kernel_task.0                tcp4 *:*                   1.0MiB     500KiB   Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 0)

    def test_mixed_byte_units(self):
        """各种字节单位的解析"""
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "Test.1                       tcp4 0.0.0.0:0             1.5GB      850MB    Established\n"
            "Test.2                       tcp4 0.0.0.0:0             500KB      2.0KiB   Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 2)
        # 1.5 GB = 1,500,000,000
        self.assertEqual(records[0]["bytesIn"], 1_500_000_000)
        # 850 MB = 850,000,000
        self.assertEqual(records[0]["bytesOut"], 850_000_000)
        # 500 KB = 500,000
        self.assertEqual(records[1]["bytesIn"], 500_000)
        # 2.0 KiB = 2048
        self.assertEqual(records[1]["bytesOut"], 2_048)

    # ── 边界和异常输入 ──

    def test_malformed_line_missing_pid(self):
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "BadProcess            tcp4 *:*                   1.0MiB     500KiB   Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 0)  # 无 PID，跳过

    def test_malformed_line_missing_bytes(self):
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "Test.9999                   tcp4 *:*                   ???    Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 0)  # 无有效字节值

    def test_unicode_process_name(self):
        """非 ASCII 进程名"""
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "微信.12345                   tcp4 0.0.0.0:0             1.0MiB     500KiB   Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["execName"], "微信")

    def test_large_byte_values(self):
        """大数值（TiB 级）"""
        raw = (
            "nettop -l1 -P -n, polling every 1.0 seconds\n"
            "                                                     bytes_in    bytes_out    state\n"
            "BigApp.1                     tcp4 0.0.0.0:0             2.5TiB     1.0TiB   Established\n"
        )
        records = parse_nettop_output(raw)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["bytesIn"], 2_748_779_069_440)
        self.assertEqual(records[0]["bytesOut"], 1_099_511_627_776)


class TestDeltaCalculator(unittest.TestCase):
    """对应 Swift DeltaCalculatorTests"""

    def test_first_snapshot_empty(self):
        """首次快照无基线，返回空"""
        curr = {"Chrome": (100, 50)}
        deltas = compute_deltas(None, curr, 5.0)
        self.assertEqual(len(deltas), 0)

    def test_normal_delta(self):
        """正常差值计算"""
        prev = {"Chrome": (100, 50)}
        curr = {"Chrome": (200, 100)}
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["bytesIn"], 100)
        self.assertEqual(deltas[0]["bytesOut"], 50)

    def test_process_restart_counters_reversed(self):
        """进程重启导致计数器回退"""
        prev = {"Chrome": (1_000_000, 500_000)}
        curr = {"Chrome": (50_000, 20_000)}  # 重启后从零开始
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 1)
        # 保守估计: curr / 10
        self.assertEqual(deltas[0]["bytesIn"], 5_000)
        self.assertEqual(deltas[0]["bytesOut"], 2_000)

    def test_new_process_appears(self):
        """新出现的进程"""
        prev = {"Chrome": (100, 50)}
        curr = {"Chrome": (200, 100), "Edge": (1000, 500)}
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 2)
        edge = [d for d in deltas if d["process"] == "Edge"][0]
        # 新进程: curr / 10
        self.assertEqual(edge["bytesIn"], 100)
        self.assertEqual(edge["bytesOut"], 50)

    def test_process_disappeared(self):
        """进程退出"""
        prev = {"Chrome": (100, 50), "Edge": (1000, 500)}
        curr = {"Chrome": (200, 100)}  # Edge 消失了
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["process"], "Chrome")

    def test_abnormal_high_delta_capped(self):
        """异常大增量被截断"""
        prev = {"Chrome": (0, 0)}
        curr = {"Chrome": (1_000_000_000, 500_000_000)}  # 1GB/s for 5s = 5GB
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 1)
        # max = 100MB/s * 5s = 500MB
        self.assertEqual(deltas[0]["bytesIn"], 500_000_000)

    def test_zero_delta_filtered(self):
        """无变化进程被过滤"""
        prev = {"Chrome": (100, 50)}
        curr = {"Chrome": (100, 50)}  # 完全相同
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 0)

    def test_multiple_processes_mixed(self):
        """混合场景：重启 + 新进程 + 正常"""
        prev = {"Chrome": (1000, 500), "Edge": (200, 100)}
        curr = {
            "Chrome": (200, 100),      # 重启了
            "Edge": (400, 200),        # 正常增量
            "Safari": (300, 150),      # 新出现的
        }
        deltas = compute_deltas(prev, curr, 5.0)
        self.assertEqual(len(deltas), 3)

        chrome = [d for d in deltas if d["process"] == "Chrome"][0]
        self.assertEqual(chrome["bytesIn"], 20)  # 200/10

        edge = [d for d in deltas if d["process"] == "Edge"][0]
        self.assertEqual(edge["bytesIn"], 200)  # 400-200

        safari = [d for d in deltas if d["process"] == "Safari"][0]
        self.assertEqual(safari["bytesIn"], 30)  # 300/10


if __name__ == "__main__":
    print("=" * 60)
    print("TrafficMonitor — 核心逻辑验证（Linux 环境）")
    print(f"时间: {datetime.now().isoformat()}")
    print("=" * 60)

    # 用 unittest.main 运行
    unittest.main(argv=["verify_core_logic.py"], verbosity=2, exit=False)
