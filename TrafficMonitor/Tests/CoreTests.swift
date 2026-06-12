import XCTest
@testable import TrafficMonitor

/// NettopParser 单元测试
final class NettopParserTests: XCTestCase {
    func testParseEmptyOutput() {
        let records = NettopParser.parse("")
        XCTAssertTrue(records.isEmpty)
    }

    func testParseSingleProcess() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
        """

        let records = NettopParser.parse(raw)
        XCTAssertEqual(records.count, 1)

        let r = records[0]
        XCTAssertEqual(r.execName, "Google Chrome")
        XCTAssertEqual(r.pid, 1234)
        XCTAssertEqual(r.bytesIn, 1_048_576)  // 1.0 MiB
        XCTAssertEqual(r.bytesOut, 512_000)   // 500 KiB
    }

    func testParseMultipleProcesses() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
        Microsoft Edge.5678          tcp4 10.0.0.1:443         2.5MB      1.0MB    Established
        """

        let records = NettopParser.parse(raw)
        XCTAssertEqual(records.count, 2)
    }

    func testParseSamePidMultipleConnections() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
        Google Chrome.1234           tcp4 10.0.0.1:80          100KiB     50.0KiB  Established
        """

        let records = NettopParser.parse(raw)
        // 同 PID 应聚合为一条
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.bytesIn, 1_048_576 + 102_400)  // 1.0MiB + 100KiB
        XCTAssertEqual(r.bytesOut, 512_000 + 51_200)    // 500KiB + 50.0KiB
    }

    func testParseZeroByteProcess() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        com.apple.WebKit.5678        tcp4 *:*                   0B         0B       Listen
        """

        let records = NettopParser.parse(raw)
        // 零流量进程应被过滤
        XCTAssertTrue(records.isEmpty)
    }

    func testParseSystemProcessExcluded() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        kernel_task.0                tcp4 *:*                   1.0MiB     500KiB   Established
        """

        let records = NettopParser.parse(raw)
        XCTAssertTrue(records.isEmpty)  // kernel_task 永远被排除
    }

    func testParseUdpOutput() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
        ---SNAPSHOT_SEPARATOR---
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Microsoft Edge.5678          udp4 *:*                   2.0MB      1.0MB    Established
        """

        let records = NettopParser.parse(raw)
        XCTAssertEqual(records.count, 2)

        let chrome = records.first { $0.execName == "Google Chrome" }
        let edge   = records.first { $0.execName == "Microsoft Edge" }
        XCTAssertNotNil(chrome)
        XCTAssertNotNil(edge)
    }

    func testParseUdpTcpSamePidMerged() {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
        ---SNAPSHOT_SEPARATOR---
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           udp4 *:*                   100KiB     50.0KiB  Established
        """

        let records = NettopParser.parse(raw)
        // 同一 PID 在 TCP 和 UDP 都出现，应合并为一条
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.bytesIn, 1_048_576 + 102_400)   // 1.0MiB + 100KiB
        XCTAssertEqual(r.bytesOut, 512_000 + 51_200)     // 500KiB + 50.0KiB
    }
}

/// DeltaCalculator 单元测试
final class DeltaCalculatorTests: XCTestCase {
    func testFirstSnapshotReturnsEmpty() {
        let records = [ProcessRecord(pid: 100, execName: "test", bytesIn: 100, bytesOut: 50)]
        let deltas = DeltaCalculator.compute(from: nil, to: records, interval: 5.0)
        XCTAssertTrue(deltas.isEmpty) // 首次快照无基线
    }

    func testNormalDelta() {
        let prev = [
            ProcessRecord(pid: 100, execName: "test", bytesIn: 100, bytesOut: 50),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "test", bytesIn: 200, bytesOut: 100),
        ]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5.0)
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        XCTAssertEqual(d.bytesIn, 100)
        XCTAssertEqual(d.bytesOut, 50)
        XCTAssertEqual(d.pid, 100)
        XCTAssertFalse(d.isEstimated)
    }

    func testProcessRestartHandling() {
        let prev = [
            ProcessRecord(pid: 100, execName: "test", bytesIn: 1_000_000, bytesOut: 500_000),
        ]
        // 进程重启，计数器归零后又涨了一些（同一 PID 被复用）
        let curr = [
            ProcessRecord(pid: 100, execName: "test", bytesIn: 50_000, bytesOut: 20_000),
        ]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5.0)
        // 重启后 delta 应为保守估计（当前值 / 10）
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        XCTAssertEqual(d.bytesIn, 5_000)   // 50_000 / 10
        XCTAssertEqual(d.bytesOut, 2_000)  // 20_000 / 10
    }

    func testPidDisappearsNoDelta() {
        // PID 101 退出了，不应该产生虚假 delta
        let prev = [
            ProcessRecord(pid: 100, execName: "Chrome", bytesIn: 5_000_000_000, bytesOut: 1_000_000_000),
            ProcessRecord(pid: 101, execName: "Chrome", bytesIn: 3_000_000_000, bytesOut: 500_000_000),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "Chrome", bytesIn: 5_100_000_000, bytesOut: 1_050_000_000),
            // PID 101 退出，无记录
        ]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 2.0)
        // 只有 PID 100 有增量，PID 101 消失不产生 delta
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        XCTAssertEqual(d.pid, 100)
        XCTAssertEqual(d.bytesIn, 100_000_000) // 5.1G - 5.0G
    }

    func testNewPidUsesFullCumulative() {
        // 真正的新 PID（不在 knownPIDs 中）：用其累计值作为增量
        let prev: [ProcessRecord] = []
        let curr = [
            ProcessRecord(pid: 200, execName: "newapp", bytesIn: 500_000, bytesOut: 200_000),
        ]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 2.0)
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        XCTAssertEqual(d.bytesIn, 500_000)
        XCTAssertEqual(d.bytesOut, 200_000)
        XCTAssertTrue(d.isEstimated)
    }

    func testReturningPidUsesConservativeEstimate() {
        // PID 在 knownPIDs 中但上次快照中没有 → /3 保守估算
        let prev: [ProcessRecord] = []
        let curr = [
            ProcessRecord(pid: 300, execName: "oldapp", bytesIn: 90_000_000, bytesOut: 60_000_000),
        ]
        let knownPIDs: Set<Int32> = [300] // 之前见过

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 2.0, knownPIDs: knownPIDs)
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        // /3 保守估算：90M/3 = 30M, 60M/3 = 20M
        XCTAssertEqual(d.bytesIn, 30_000_000)
        XCTAssertEqual(d.bytesOut, 20_000_000)
        XCTAssertTrue(d.isEstimated)
    }

    func testGenuinelyNewPidCappedAtLimit() {
        // 真正的新 PID，但累计值异常大 → 被 10 MB/s * interval 上限截断
        let prev: [ProcessRecord] = []
        let curr = [
            ProcessRecord(pid: 999, execName: "huge", bytesIn: 1_000_000_000, bytesOut: 0),
        ]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5.0)
        XCTAssertEqual(deltas.count, 1)
        // 10_000_000 * 5 = 50_000_000 上限
        XCTAssertEqual(deltas[0].bytesIn, 50_000_000)
        XCTAssertTrue(deltas[0].isEstimated)
    }

    func testZeroDeltaFiltered() {
        let prev = [
            ProcessRecord(pid: 100, execName: "idle", bytesIn: 100, bytesOut: 50),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "idle", bytesIn: 100, bytesOut: 50),
        ]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5.0)
        XCTAssertTrue(deltas.isEmpty)
    }
}
