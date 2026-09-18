import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - DataStore CRUD 集成测试
// ============================================================

final class DataStoreTests: XCTestCase {
    var store: DataStore!
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrafficMonitorTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.db")
        store = DataStore()
        try await store.setup(at: dbURL)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Setup

    func testSetupCreatesDatabaseFile() async throws {
        let dbURL = tempDir.appendingPathComponent("test.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    // MARK: - Insert & Query

    func testInsertAndQuerySummary() async throws {
        let now = Date().timeIntervalSince1970
        let events = [
            TrafficEvent(id: nil, timestamp: now - 10, interval: 5,
                         processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                         bytesIn: 1000, bytesOut: 500),
            TrafficEvent(id: nil, timestamp: now - 5, interval: 5,
                         processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                         bytesIn: 500, bytesOut: 200),
            TrafficEvent(id: nil, timestamp: now - 8, interval: 5,
                         processKey: "Edge", bundleId: nil, displayName: "Edge",
                         bytesIn: 200, bytesOut: 100),
        ]
        try await store.insertEvents(events)

        let summaries = try await store.querySummary(since: now - 60)
        XCTAssertEqual(summaries.count, 2)

        let chrome = summaries.first { $0.processKey == "Chrome" }
        XCTAssertNotNil(chrome)
        XCTAssertEqual(chrome!.totalIn, 1500)
        XCTAssertEqual(chrome!.totalOut, 700)
        XCTAssertEqual(chrome!.sampleCount, 2)

        let edge = summaries.first { $0.processKey == "Edge" }
        XCTAssertNotNil(edge)
        XCTAssertEqual(edge!.totalIn, 200)
        XCTAssertEqual(edge!.totalOut, 100)
        XCTAssertEqual(edge!.sampleCount, 1)
    }

    func testQuerySummaryTimeRange() async throws {
        let now = Date().timeIntervalSince1970
        let old = TrafficEvent(id: nil, timestamp: now - 3600, interval: 5,
                               processKey: "old", bundleId: nil, displayName: "old",
                               bytesIn: 100, bytesOut: 0)
        let recent = TrafficEvent(id: nil, timestamp: now - 30, interval: 5,
                                  processKey: "recent", bundleId: nil, displayName: "recent",
                                  bytesIn: 200, bytesOut: 0)
        try await store.insertEvents([old, recent])

        // Query last 60 seconds only
        let summaries = try await store.querySummary(since: now - 60)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].processKey, "recent")
    }

    func testQuerySummaryLimit() async throws {
        let now = Date().timeIntervalSince1970
        var events: [TrafficEvent] = []
        for i in 0..<10 {
            events.append(TrafficEvent(
                id: nil, timestamp: now - Double(i) * 5, interval: 5,
                processKey: "proc\(i)", bundleId: nil, displayName: "proc\(i)",
                bytesIn: 100, bytesOut: 0
            ))
        }
        try await store.insertEvents(events)

        let limited = try await store.querySummary(since: now - 300, limit: 3)
        XCTAssertEqual(limited.count, 3)
    }

    // MARK: - Timeline

    func testQueryTimeline() async throws {
        let now = Date().timeIntervalSince1970
        var events: [TrafficEvent] = []
        for i in 0..<5 {
            events.append(TrafficEvent(
                id: nil, timestamp: now - Double(i) * 120, interval: 5,
                processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                bytesIn: Int64((i + 1) * 100), bytesOut: Int64(i * 50)
            ))
        }
        try await store.insertEvents(events)

        let timeline = try await store.queryTimeline(
            processKey: "Chrome", since: now - 3600, bucketSeconds: 60
        )
        // All points in timeline should have positive timestamps
        XCTAssertGreaterThan(timeline.count, 0)
        for point in timeline {
            XCTAssertGreaterThan(point.timestamp, now - 3600)
        }
    }

    /// 查一个从没传过流量的进程：结论不是「没有数据」，而是「这段时间它一直是 0」——
    /// 采集器在跑（同一分钟别的进程有行），所以有采集的桶都要回 0。
    /// 只有整分钟谁都没数据（应用关了 / 机器睡了）才不返回，画图时断成洞。
    func testQueryTimelineForUnknownProcessIsZeroNotEmpty() async throws {
        let now = Date().timeIntervalSince1970
        let events = [TrafficEvent(
            id: nil, timestamp: now, interval: 5,
            processKey: "Chrome", bundleId: nil, displayName: "Chrome",
            bytesIn: 100, bytesOut: 0
        )]
        try await store.insertEvents(events)

        let timeline = try await store.queryTimeline(
            processKey: "DoesNotExist", since: now - 3600
        )
        XCTAssertEqual(timeline.count, 1, "只有 now 那一分钟有采集")
        XCTAssertEqual(timeline.first?.totalBytes, 0, "没传过 = 0，而不是空洞")
    }

    // MARK: - Delete

    func testDeleteBefore() async throws {
        let now = Date().timeIntervalSince1970
        let old = TrafficEvent(id: nil, timestamp: now - 7200, interval: 5,
                               processKey: "old", bundleId: nil, displayName: "old",
                               bytesIn: 100, bytesOut: 0)
        let recent = TrafficEvent(id: nil, timestamp: now - 10, interval: 5,
                                  processKey: "recent", bundleId: nil, displayName: "recent",
                                  bytesIn: 200, bytesOut: 0)
        try await store.insertEvents([old, recent])

        try await store.deleteBefore(now - 3600)

        let summaries = try await store.querySummary(since: now - 7200)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].processKey, "recent")
    }

    // MARK: - Time Range

    func testTimeRange() async throws {
        let now = Date().timeIntervalSince1970
        let events = [
            TrafficEvent(id: nil, timestamp: now - 3600, interval: 5,
                         processKey: "a", bundleId: nil, displayName: "a",
                         bytesIn: 1, bytesOut: 0),
            TrafficEvent(id: nil, timestamp: now - 10, interval: 5,
                         processKey: "b", bundleId: nil, displayName: "b",
                         bytesIn: 1, bytesOut: 0),
        ]
        try await store.insertEvents(events)

        let range = try await store.timeRange()
        XCTAssertEqual(range.first, now - 3600, accuracy: 1)
        XCTAssertEqual(range.last, now - 10, accuracy: 1)
    }

    func testTimeRangeEmptyDatabase() async throws {
        let range = try await store.timeRange()
        XCTAssertEqual(range.first, 0)
        XCTAssertEqual(range.last, 0)
    }

    // MARK: - Size

    func testDatabaseSizeReturnsPositive() async throws {
        let now = Date().timeIntervalSince1970
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: now, interval: 5,
                         processKey: "test", bundleId: nil, displayName: "test",
                         bytesIn: 100, bytesOut: 0)
        ])
        let size = await store.databaseSize()
        XCTAssertGreaterThan(size, 0)
    }

    func testEmptyDatabaseSize() async throws {
        let size = await store.databaseSize()
        // After setup, even empty DB has some size (WAL files, etc.)
        XCTAssertGreaterThanOrEqual(size, 0)
    }

    // MARK: - Empty Query

    func testQueryEmptyDatabase() async throws {
        let summaries = try await store.querySummary(since: 0)
        XCTAssertTrue(summaries.isEmpty)
    }
}

// ============================================================
// MARK: - 落库全链路集成测试: event → 批量 INSERT → 汇总查询
// ============================================================

final class FullPipelineIntegrationTests: XCTestCase {
    var store: DataStore!
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrafficPipeline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("pipeline.db")
        store = DataStore()
        try await store.setup(at: dbURL)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 分块批量写入：行数超过 `Constants.insertChunkSize` 时要跨多条 INSERT 语句
    func testBatchInsertAcrossChunks() async throws {
        let ts0 = Date().timeIntervalSince1970
        let count = Constants.insertChunkSize * 2 + 7
        let events = (0 ..< count).map { i in
            TrafficEvent(id: nil, timestamp: ts0, interval: Constants.storageBucketSeconds,
                         processKey: "p\(i)", bundleId: nil, displayName: "p\(i)",
                         bytesIn: Int64(i), bytesOut: Int64(i * 2))
        }
        try await store.insertEvents(events)

        let summaries = try await store.querySummary(since: ts0 - 10)
        XCTAssertEqual(summaries.count, count)
        XCTAssertEqual(summaries.reduce(0) { $0 + $1.totalIn }, Int64((0 ..< count).reduce(0, +)))
    }

    /// 保留期清理
    func testPruneExpiredDropsOldRowsOnly() async throws {
        let now = Date().timeIntervalSince1970
        let old = now - Constants.retentionDays * 86400 - 3600
        try await store.insertEvents([
            TrafficEvent(id: nil, timestamp: old, interval: 60, processKey: "old",
                         bundleId: nil, displayName: "old", bytesIn: 1, bytesOut: 1),
            TrafficEvent(id: nil, timestamp: now, interval: 60, processKey: "new",
                         bundleId: nil, displayName: "new", bytesIn: 2, bytesOut: 2),
        ])
        try await store.pruneExpired()

        let all = try await store.querySummary(since: 0)
        XCTAssertEqual(all.map(\.processKey), ["new"])
    }

    /// 模拟从差值到写入再到查询的完整数据流
    func testDeltaToEventToDBFullChain() async throws {
        let ts0 = Date().timeIntervalSince1970

        // 直接构造事件，绕开依赖真实进程的身份解析
        let events = [
            TrafficEvent(id: nil, timestamp: ts0, interval: 5,
                         processKey: "Chrome", bundleId: nil, displayName: "Chrome",
                         bytesIn: 500_000, bytesOut: 300_000),
            TrafficEvent(id: nil, timestamp: ts0, interval: 5,
                         processKey: "Edge", bundleId: nil, displayName: "Edge",
                         bytesIn: 200_000, bytesOut: 100_000),
        ]

        // Insert
        try await store.insertEvents(events)

        // Query back
        let summaries = try await store.querySummary(since: ts0 - 10)
        XCTAssertEqual(summaries.count, 2)
        let chrome = summaries.first { $0.displayName == "Chrome" }
        XCTAssertNotNil(chrome)
        XCTAssertEqual(chrome!.totalIn, 500_000)
        XCTAssertEqual(chrome!.totalOut, 300_000)
    }
}

// ============================================================
// MARK: - 数据库文件整理
// ============================================================

/// SQLite 删除行只把页挂到 freelist，文件不会缩小。
/// 这组测试验证「浪费明显时才整理、整理后确实变小」。
final class DatabaseCompactionTests: XCTestCase {
    private var store: DataStore!
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-\(UUID().uuidString).db")
        store = DataStore()
        try await store.setup(at: url)
    }

    override func tearDown() async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + suffix))
        }
    }

    private func fill(_ count: Int, daysAgo: Double) async throws {
        let base = Date().timeIntervalSince1970 - daysAgo * 86_400
        let events = (0..<count).map { i in
            TrafficEvent(id: nil, timestamp: base + Double(i), interval: 60,
                         processKey: "proc\(i % 40)", bundleId: nil,
                         displayName: "填充用的长名字以便撑大页面 \(i)",
                         bytesIn: Int64(i), bytesOut: Int64(i))
        }
        try await store.insertEvents(events)
    }

    /// 删掉绝大部分行之后，整理必须真的把空间还给系统
    func testCompactReclaimsSpaceAfterLargeDelete() async throws {
        try await fill(20_000, daysAgo: 90)
        try await fill(200, daysAgo: 0)
        try await store.checkpoint()
        let filled = await store.databaseSize()

        try await store.pruneExpired(retentionDays: 30)
        try await store.checkpoint()
        let afterDelete = await store.databaseSize()
        // 关键：只删不整理，文件一点没小 —— 这正是需要 VACUUM 的原因
        XCTAssertEqual(afterDelete, filled, "仅删除不会把空间还给系统")

        let reclaimed = try await store.compactIfWasteful()
        let afterCompact = await store.databaseSize()
        XCTAssertGreaterThan(reclaimed, 0, "浪费明显时应当有回收")
        XCTAssertLessThan(afterCompact, afterDelete / 2, "整理后文件应大幅缩小")
        XCTAssertEqual(reclaimed, filled - afterCompact, "回收量应等于实际缩小量")
    }

    /// VACUUM 会把整个新库写进 WAL；不再 checkpoint 一次的话，
    /// 主库虽然缩了、WAL 却撑得更大，总占用反而上升。
    func testCompactAlsoTruncatesWriteAheadLog() async throws {
        try await fill(20_000, daysAgo: 90)
        try await fill(200, daysAgo: 0)
        try await store.pruneExpired(retentionDays: 30)
        _ = try await store.compactIfWasteful()

        let walPath = url.path + "-wal"
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walPath))?[.size] as? Int64 ?? 0
        XCTAssertLessThan(walSize, 1 << 20, "整理后 WAL 应已被截断")
    }

    /// 数据紧凑时不该白白重写整个文件
    func testCompactIsNoOpWhenDatabaseIsDense() async throws {
        try await fill(2_000, daysAgo: 0)
        let reclaimed = try await store.compactIfWasteful()
        XCTAssertEqual(reclaimed, 0, "没有明显浪费时不应触发 VACUUM")
    }

    /// 低于绝对字节阈值时也不做 —— 小库整理的收益还不够开销
    func testCompactRespectsMinimumBytesThreshold() async throws {
        try await fill(2_000, daysAgo: 90)
        try await store.pruneExpired(retentionDays: 30)
        let reclaimed = try await store.compactIfWasteful(minimumFreeBytes: 1 << 30)
        XCTAssertEqual(reclaimed, 0)
    }

    /// 整理不能弄丢数据
    func testCompactPreservesRemainingRows() async throws {
        try await fill(20_000, daysAgo: 90)
        try await fill(500, daysAgo: 1)
        try await store.pruneExpired(retentionDays: 30)

        let before = try await store.querySummary(since: 0)
        let beforeTotal = before.reduce(0) { $0 + $1.totalBytes }
        _ = try await store.compactIfWasteful()
        let after = try await store.querySummary(since: 0)

        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.reduce(0) { $0 + $1.totalBytes }, beforeTotal)
    }
}


// ============================================================
// MARK: - 时间线峰值（含迁移前的老数据）
// ============================================================

/// 落库桶会把一分钟内的突发摊平，所以每行额外记「桶内见过的最高瞬时速率」。
/// 这里只测存储/查询这一层：
/// - 老行（迁移前写库，峰值列默认 0）要退回**该行自己的** `bytes / interval`，
///   而不是拿展示桶长度去除 —— 否则以后把粒度改成 5s/10s，老行会整体高估。
/// - 一个展示桶里聚了多行时，流量求和、峰值取**最大**。
final class TimelinePeakTests: XCTestCase {
    var store: DataStore!
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TimelinePeak_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore()
        try await store.setup(at: tempDir.appendingPathComponent("peak.db"))
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func event(at ts: TimeInterval, key: String, interval: TimeInterval,
                       in bytesIn: Int64, out bytesOut: Int64,
                       peakIn: Double = 0, peakOut: Double = 0) -> TrafficEvent {
        TrafficEvent(id: nil, timestamp: ts, interval: interval, processKey: key,
                     bundleId: nil, displayName: key,
                     bytesIn: bytesIn, bytesOut: bytesOut, peakIn: peakIn, peakOut: peakOut)
    }

    func testLegacyRowFallsBackToItsOwnInterval() async throws {
        let ts = 1_700_000_000.0
        try await store.insertEvents([
            event(at: ts, key: "legacy", interval: 60, in: 6_000, out: 1_200),
        ])

        let points = try await store.queryTimeline(processKey: "legacy", since: ts - 1, bucketSeconds: 300)
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point.peakIn, 100, accuracy: 0.001, "6000 / 60s")
        XCTAssertEqual(point.peakOut, 20, accuracy: 0.001, "1200 / 60s")
    }

    func testAggregatedBucketTakesMaxPeak() async throws {
        let ts = 1_700_000_000.0
        try await store.insertEvents([
            event(at: ts, key: "burst", interval: 60, in: 600, out: 0, peakIn: 900),
            event(at: ts + 60, key: "burst", interval: 60, in: 300, out: 0,
                  peakIn: 12_345, peakOut: 500),
        ])

        let points = try await store.queryTimeline(processKey: "burst", since: ts - 1, bucketSeconds: 300)
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point.bytesIn, 900, "同一个展示桶里流量求和")
        XCTAssertEqual(point.peakIn, 12_345, accuracy: 0.001, "峰值取最大，不是平均也不是最后一行")
        XCTAssertEqual(point.peakOut, 500, accuracy: 0.001)
    }
}


// ============================================================
// MARK: - 时间线的「有采集」与「空洞」
// ============================================================

/// 时间线不能只回「有流量的桶」：
/// - 监控器在跑、该进程没流量的桶 → 回 0（画出来是贴地的线，说明「确实没传」）；
/// - 整分钟谁都没数据（应用关了 / 机器睡了）→ **不返回**，上层据此断线。
///
/// 否则 07:58 和 14:08 两次突发之间会被连成一条斜线，看着像一直在传。
final class TimelineCoverageTests: XCTestCase {
    var store: DataStore!
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TimelineCoverage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore()
        try await store.setup(at: tempDir.appendingPathComponent("coverage.db"))
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func event(at ts: TimeInterval, key: String,
                       in bytesIn: Int64, out bytesOut: Int64,
                       peakIn: Double = 0) -> TrafficEvent {
        TrafficEvent(id: nil, timestamp: ts, interval: 60, processKey: key,
                     bundleId: nil, displayName: key,
                     bytesIn: bytesIn, bytesOut: bytesOut, peakIn: peakIn, peakOut: 0)
    }

    func testFillsIdleBucketsWithZeroAndSkipsUncoveredOnes() async throws {
        let base = 1_700_000_040.0            // 整分钟对齐
        try await store.insertEvents([
            // 别的进程在这三分钟有流量 → 采集器在跑
            event(at: base,       key: "other", in: 10, out: 0),
            event(at: base + 60,  key: "other", in: 10, out: 0),
            event(at: base + 120, key: "other", in: 10, out: 0),
            // 被测进程只在首尾两分钟传了东西
            event(at: base,       key: "mine", in: 1_000, out: 100, peakIn: 500),
            event(at: base + 120, key: "mine", in: 2_000, out: 200, peakIn: 900),
        ])

        let points = try await store.queryTimeline(
            processKey: "mine", since: base - 1, until: base + 200, bucketSeconds: 60)

        XCTAssertEqual(points.map(\.timestamp), [base, base + 60, base + 120],
                       "base+180 谁都没数据 → 不返回（空洞）")
        XCTAssertEqual(points[0].peakIn, 500, accuracy: 0.001)
        XCTAssertEqual(points[1].bytesIn, 0, "采集器在跑、进程没流量 = 真实的 0")
        XCTAssertEqual(points[1].bytesOut, 0)
        XCTAssertEqual(points[2].bytesIn, 2_000)
    }
}
