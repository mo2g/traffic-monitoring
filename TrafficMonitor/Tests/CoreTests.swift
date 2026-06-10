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
}

/// DeltaCalculator 单元测试
final class DeltaCalculatorTests: XCTestCase {
    func testFirstSnapshotReturnsEmpty() {
        let snapshot = ProcessSnapshot(
            timestamp: Date(),
            records: [ProcessIdentifier(bundleId: nil, execName: "test"): (100, 50)],
            rawRecords: []
        )

        let deltas = DeltaCalculator.compute(from: nil, to: snapshot, interval: 5.0)
        XCTAssertTrue(deltas.isEmpty) // 首次快照无基线
    }

    func testNormalDelta() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")

        let prev = ProcessSnapshot(
            timestamp: Date(timeIntervalSinceNow: -5),
            records: [ident: (bytesIn: 100, bytesOut: 50)],
            rawRecords: []
        )
        let curr = ProcessSnapshot(
            timestamp: Date(),
            records: [ident: (bytesIn: 200, bytesOut: 100)],
            rawRecords: []
        )

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5.0)
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        XCTAssertEqual(d.bytesIn, 100)
        XCTAssertEqual(d.bytesOut, 50)
    }

    func testProcessRestartHandling() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")

        let prev = ProcessSnapshot(
            timestamp: Date(timeIntervalSinceNow: -5),
            records: [ident: (bytesIn: 1_000_000, bytesOut: 500_000)],
            rawRecords: []
        )
        // 进程重启，计数器归零后又涨了一些
        let curr = ProcessSnapshot(
            timestamp: Date(),
            records: [ident: (bytesIn: 50_000, bytesOut: 20_000)],
            rawRecords: []
        )

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5.0)
        // 重启后 delta 应为保守估计（当前值 / 10）
        XCTAssertEqual(deltas.count, 1)
        let d = deltas[0]
        XCTAssertEqual(d.bytesIn, 5_000)   // 50_000 / 10
        XCTAssertEqual(d.bytesOut, 2_000)  // 20_000 / 10
    }
}
