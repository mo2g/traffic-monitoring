import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - TrafficPipeline 聚合与快照测试
// ============================================================

/// 聚合逻辑现在在 `TrafficPipeline` actor 内（PID → ProcessIdentifier → 累加），
/// 这里用构造出来的帧走一遍真实链路。
///
/// 用不存在的 PID：解析器会自然 fallback 到 execName 作为聚合键，
/// 测试因此不依赖机器上跑着什么应用。
final class TrafficPipelineTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
    }

    override func tearDown() async throws {
        await pipeline.reset()
    }

    private func frame(_ deltas: [PIDDelta], baseline: Bool = false,
                       interval: TimeInterval = 2, at: Date = Date()) -> TrafficFrame {
        TrafficFrame(deltas: deltas, timestamp: at, interval: interval, isBaseline: baseline)
    }

    func testBaselineFrameDoesNotCountTraffic() async {
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_001, execName: "basetest", bytesIn: 10_000, bytesOut: 5_000)],
            baseline: true
        ))
        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "basetest" }
        XCTAssertNotNil(row, "首帧应把进程登记进来")
        XCTAssertEqual(row?.totalBytes, 0, "首帧的累计值不应计入流量")
    }

    func testDeltaFrameAccumulates() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_002, execName: "acc", bytesIn: 1_000, bytesOut: 500),
        ]))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_002, execName: "acc", bytesIn: 2_000, bytesOut: 100),
        ], at: Date().addingTimeInterval(2)))

        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "acc" }
        XCTAssertEqual(row?.totalIn, 3_000)
        XCTAssertEqual(row?.totalOut, 600)
    }

    func testMultiplePIDsWithSameKeyAggregate() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_010, execName: "same", bytesIn: 1_000, bytesOut: 500),
            PIDDelta(pid: 999_011, execName: "same", bytesIn: 500, bytesOut: 200),
        ]))
        let snap = await pipeline.makeSnapshot()
        let rows = snap.rows.filter { $0.key == "same" }
        XCTAssertEqual(rows.count, 1, "同一标识的多个 PID 应聚合成一行")
        XCTAssertEqual(rows[0].totalIn, 1_500)
        XCTAssertEqual(rows[0].totalOut, 700)
    }

    func testRateUsesFrameInterval() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_020, execName: "rate", bytesIn: 2_000, bytesOut: 1_000)],
            interval: 2
        ))
        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "rate" }
        XCTAssertEqual(row?.rxRate ?? 0, 1_000, accuracy: 1)
        XCTAssertEqual(row?.txRate ?? 0, 500, accuracy: 1)
    }

    /// 进程本帧没有流量时速率必须归零，否则表格会一直挂着上一次的速率
    func testIdleProcessRateResetsToZero() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_030, execName: "idle", bytesIn: 2_000, bytesOut: 0)]
        ))
        _ = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_031, execName: "other", bytesIn: 100, bytesOut: 0)],
            at: Date().addingTimeInterval(2)
        ))
        let snap = await pipeline.makeSnapshot()
        let row = snap.rows.first { $0.key == "idle" }
        XCTAssertEqual(row?.rxRate, 0)
        XCTAssertEqual(row?.totalIn, 2_000, "速率归零不应影响累计量")
    }

    func testSnapshotSortedByTotalDescending() async {
        _ = await pipeline.ingest(frame([], baseline: true))
        _ = await pipeline.ingest(frame([
            PIDDelta(pid: 999_040, execName: "small", bytesIn: 10, bytesOut: 0),
            PIDDelta(pid: 999_041, execName: "big", bytesIn: 10_000, bytesOut: 0),
            PIDDelta(pid: 999_042, execName: "mid", bytesIn: 500, bytesOut: 0),
        ]))
        let snap = await pipeline.makeSnapshot()
        let keys = snap.rows.prefix(3).map(\.key)
        XCTAssertEqual(keys, ["big", "mid", "small"])
        XCTAssertEqual(snap.totalBytes, 10_510)
    }

    /// 窗口不可见时不生成快照 —— 这是把主线程从每帧唤醒中解放出来的关键
    func testHiddenUIProducesNoSnapshot() async {
        await pipeline.setUIVisible(false)
        let pushed = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_050, execName: "hidden", bytesIn: 1_000, bytesOut: 0)]
        ))
        XCTAssertNil(pushed, "不可见时不应生成快照")

        await pipeline.setUIVisible(true)
        let resumed = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_050, execName: "hidden", bytesIn: 1_000, bytesOut: 0)],
            at: Date().addingTimeInterval(2)
        ))
        XCTAssertNotNil(resumed, "重新可见时应立刻补一帧")
        XCTAssertEqual(resumed?.rows.first { $0.key == "hidden" }?.totalIn, 2_000,
                       "不可见期间的流量仍要照常累计")
    }

    /// 两帧间隔小于 uiRefreshInterval 时不重复推送
    func testSnapshotThrottled() async {
        await pipeline.setUIVisible(true)
        let now = Date()
        _ = await pipeline.ingest(frame([], baseline: true, at: now))
        let tooSoon = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_060, execName: "throttle", bytesIn: 1, bytesOut: 0)],
            at: now.addingTimeInterval(Constants.uiRefreshInterval / 2)
        ))
        XCTAssertNil(tooSoon)

        let due = await pipeline.ingest(frame(
            [PIDDelta(pid: 999_060, execName: "throttle", bytesIn: 1, bytesOut: 0)],
            at: now.addingTimeInterval(Constants.uiRefreshInterval + 0.1)
        ))
        XCTAssertNotNil(due)
    }
}
