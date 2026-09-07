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

// ============================================================
// MARK: - 统计窗口切换
// ============================================================

/// 切换「今日 / 本周 / 本月」时，管线的历史部分必须是**替换**而不是累加，
/// 且不能动到尚未落库的实时部分。
final class TimeRangeReloadTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws { await pipeline.reset() }
    override func tearDown() async throws { await pipeline.reset() }

    private func summary(_ key: String, in bytesIn: Int64, out bytesOut: Int64) -> ProcessSummary {
        ProcessSummary(processKey: key, bundleId: nil, displayName: key,
                       totalIn: bytesIn, totalOut: bytesOut, sampleCount: 1,
                       firstSeen: 0, lastSeen: 0)
    }

    private func row(_ key: String) async -> ProcessRow? {
        await pipeline.makeSnapshot().rows.first { $0.key == key }
    }

    private func feed(_ deltas: [PIDDelta]) async {
        _ = await pipeline.ingest(TrafficFrame(deltas: [], timestamp: Date(),
                                               interval: 0, isBaseline: true))
        _ = await pipeline.ingest(TrafficFrame(deltas: deltas, timestamp: Date(),
                                               interval: 2, isBaseline: false))
    }

    func testReloadReplacesRatherThanAccumulates() async {
        await pipeline.reloadHistorical([summary("a", in: 1_000, out: 100)])
        let first = await row("a")
        XCTAssertEqual(first?.totalIn, 1_000)

        // 换一个更大的窗口 → 应替换为新值，而不是变成 1000+5000
        await pipeline.reloadHistorical([summary("a", in: 5_000, out: 500)])
        let second = await row("a")
        XCTAssertEqual(second?.totalIn, 5_000)
        XCTAssertEqual(second?.totalOut, 500)
    }

    func testLiveBytesSurviveReload() async {
        await feed([PIDDelta(pid: 999_100, execName: "live", bytesIn: 700, bytesOut: 300)])
        let live = await row("live")
        XCTAssertEqual(live?.totalIn, 700)

        await pipeline.reloadHistorical([summary("live", in: 2_000, out: 0)])
        let merged = await row("live")
        // 历史 2000 + 尚未落库的实时 700
        XCTAssertEqual(merged?.totalIn, 2_700)
        XCTAssertEqual(merged?.totalOut, 300)
    }

    /// 窗口缩小后落在窗口外的进程，其历史必须清零，否则总数会带上窗口外的流量
    func testProcessOutsideNewWindowIsDropped() async {
        await pipeline.reloadHistorical([
            summary("kept", in: 100, out: 0),
            summary("dropped", in: 900, out: 0),
        ])
        let wide = await pipeline.makeSnapshot()
        XCTAssertEqual(wide.totalBytes, 1_000)

        await pipeline.reloadHistorical([summary("kept", in: 100, out: 0)])
        let narrow = await pipeline.makeSnapshot()
        XCTAssertEqual(narrow.totalBytes, 100)
        XCTAssertNil(narrow.rows.first { $0.key == "dropped" }, "窗口外且无实时数据的进程应移出列表")
    }

    /// 有实时数据的进程即使不在新窗口的历史里，也要留在列表上（历史归零、实时保留）
    func testActiveProcessStaysWithZeroedHistory() async {
        await feed([PIDDelta(pid: 999_101, execName: "active", bytesIn: 50, bytesOut: 0)])
        await pipeline.reloadHistorical([summary("active", in: 5_000, out: 0)])
        let withHistory = await row("active")
        XCTAssertEqual(withHistory?.totalIn, 5_050)

        await pipeline.reloadHistorical([])   // 新窗口里没有它的历史
        let liveOnly = await row("active")
        XCTAssertEqual(liveOnly?.totalIn, 50, "只剩尚未落库的实时部分")
    }
}

// ============================================================
// MARK: - 时间窗口边界
// ============================================================

final class TimeRangeBoundaryTests: XCTestCase {
    /// 标签写着「今日」，起点就该是今天零点，而不是往前推 24 小时
    @MainActor
    func testTodayStartsAtMidnight() {
        let start = DashboardViewModel.TimeRange.today.start
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: start)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0)
        XCTAssertTrue(Calendar.current.isDateInToday(start))
    }

    @MainActor
    func testRangesAreOrderedFromNarrowToWide() {
        let today = DashboardViewModel.TimeRange.today.start
        let week = DashboardViewModel.TimeRange.week.start
        let month = DashboardViewModel.TimeRange.month.start
        XCTAssertLessThanOrEqual(week, today)
        XCTAssertLessThanOrEqual(month, today)
    }

    @MainActor
    func testAllStartsAreInThePast() {
        for range in DashboardViewModel.TimeRange.allCases {
            XCTAssertLessThanOrEqual(range.start, Date(), "\(range.rawValue) 起点不应在未来")
        }
    }
}

// ============================================================
// MARK: - 排除进程
// ============================================================

final class ExcludedProcessTests: XCTestCase {
    private let pipeline = TrafficPipeline.shared

    override func setUp() async throws {
        await pipeline.reset()
        await pipeline.setExcludedProcesses([])
    }
    override func tearDown() async throws {
        await pipeline.setExcludedProcesses([])
        await pipeline.reset()
    }

    private func feed(_ deltas: [PIDDelta]) async {
        _ = await pipeline.ingest(TrafficFrame(deltas: [], timestamp: Date(),
                                               interval: 0, isBaseline: true))
        _ = await pipeline.ingest(TrafficFrame(deltas: deltas, timestamp: Date(),
                                               interval: 2, isBaseline: false))
    }

    func testExcludedProcessIsNotCounted() async {
        await pipeline.setExcludedProcesses(["noisy"])
        await feed([
            PIDDelta(pid: 999_200, execName: "noisy", bytesIn: 9_000, bytesOut: 0),
            PIDDelta(pid: 999_201, execName: "wanted", bytesIn: 100, bytesOut: 0),
        ])
        let snapshot = await pipeline.makeSnapshot()
        XCTAssertNil(snapshot.rows.first { $0.key == "noisy" })
        XCTAssertEqual(snapshot.rows.first { $0.key == "wanted" }?.totalIn, 100)
        XCTAssertEqual(snapshot.totalBytes, 100, "被排除的进程不应计入总数")
    }

    /// 改设置后应立即生效，不需要重启 —— 已累计的数据一并清出
    func testSettingExclusionPurgesExistingStats() async {
        await feed([PIDDelta(pid: 999_210, execName: "later", bytesIn: 5_000, bytesOut: 0)])
        let before = await pipeline.makeSnapshot()
        XCTAssertEqual(before.totalBytes, 5_000)

        await pipeline.setExcludedProcesses(["later"])
        let after = await pipeline.makeSnapshot()
        XCTAssertNil(after.rows.first { $0.key == "later" })
        XCTAssertEqual(after.totalBytes, 0)
    }

    func testMatchingIsCaseInsensitive() async {
        await pipeline.setExcludedProcesses(["mdnsresponder"])
        await feed([PIDDelta(pid: 999_220, execName: "mDNSResponder", bytesIn: 500, bytesOut: 0)])
        let snapshot = await pipeline.makeSnapshot()
        XCTAssertTrue(snapshot.rows.isEmpty)
    }

    func testNonMatchingNameIsUnaffected() async {
        await pipeline.setExcludedProcesses(["something-else"])
        await feed([PIDDelta(pid: 999_230, execName: "keepme", bytesIn: 42, bytesOut: 0)])
        let snapshot = await pipeline.makeSnapshot()
        XCTAssertEqual(snapshot.rows.first { $0.key == "keepme" }?.totalIn, 42)
    }
}

// ============================================================
// MARK: - 排除列表解析
// ============================================================

final class ExcludedListParsingTests: XCTestCase {
    func testSplitsOnCommasAndNewlines() {
        let parsed = Preferences.parseExcluded("a, b，c\nd")
        XCTAssertEqual(parsed, ["a", "b", "c", "d"], "半角逗号、全角逗号、换行都应作为分隔符")
    }

    func testTrimsAndLowercases() {
        XCTAssertEqual(Preferences.parseExcluded("  mDNSResponder  ,  WeChat "),
                       ["mdnsresponder", "wechat"])
    }

    func testDropsEmptyEntries() {
        XCTAssertEqual(Preferences.parseExcluded(",,  ,a,"), ["a"])
    }

    func testEmptyInputYieldsEmptySet() {
        XCTAssertTrue(Preferences.parseExcluded("   ").isEmpty)
    }
}
