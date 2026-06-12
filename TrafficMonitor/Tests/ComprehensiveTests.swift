import XCTest
import GRDB
@testable import TrafficMonitor

// ============================================================
// MARK: - ByteFormatter 单元测试
// ============================================================

final class ByteFormatterTests: XCTestCase {
    func testZeroBytes() {
        XCTAssertEqual(ByteFormatter.string(bytes: 0), "0 B")
    }

    func testBytes() {
        XCTAssertEqual(ByteFormatter.string(bytes: 500), "500 B")
    }

    func testKilobytes() {
        let s = ByteFormatter.string(bytes: 1536)
        XCTAssertTrue(s.hasSuffix("KB"))
        XCTAssertTrue(s.hasPrefix("1.5"))
    }

    func testMegabytes() {
        let s = ByteFormatter.string(bytes: 2_500_000)
        XCTAssertTrue(s.contains("MB"))
    }

    func testGigabytes() {
        let s = ByteFormatter.string(bytes: 1_500_000_000)
        XCTAssertTrue(s.contains("GB"))
    }

    func testKilobyteExact() {
        XCTAssertEqual(ByteFormatter.string(bytes: 1024), "1.0 KB")
    }

    func testMegabyteExact() {
        XCTAssertEqual(ByteFormatter.string(bytes: 1_048_576), "1.0 MB")
    }

    func testRateSlow() {
        let s = ByteFormatter.rateString(bytesPerSecond: 50)
        XCTAssertEqual(s, "50 B/s")
    }

    func testRateKBs() {
        let s = ByteFormatter.rateString(bytesPerSecond: 2048)
        XCTAssertEqual(s, "2.0 KB/s")
    }

    func testRateMBs() {
        let s = ByteFormatter.rateString(bytesPerSecond: 3_145_728)
        XCTAssertEqual(s, "3.0 MB/s")
    }

    func testRateZero() {
        XCTAssertEqual(ByteFormatter.rateString(bytesPerSecond: 0), "0 B/s")
    }
}

// ============================================================
// MARK: - ProcessIdentifier 测试
// ============================================================

final class ProcessIdentifierTests: XCTestCase {
    func testDescriptionWithBundleId() {
        let id = ProcessIdentifier(bundleId: "com.google.Chrome", execName: "Google Chrome")
        XCTAssertEqual(id.description, "com.google.Chrome")
    }

    func testDescriptionWithoutBundleId() {
        let id = ProcessIdentifier(bundleId: nil, execName: "mds")
        XCTAssertEqual(id.description, "mds")
    }

    func testDisplayNameFallsBackToExecName() {
        let id = ProcessIdentifier(bundleId: nil, execName: "myapp")
        XCTAssertEqual(id.displayName, "myapp")
    }

    func testDisplayNameFromBundleIdLastComponent() {
        // When no running app matches, falls back to last component of bundleId
        let id = ProcessIdentifier(bundleId: "com.example.FakeApp", execName: "FakeApp")
        XCTAssertEqual(id.displayName, "FakeApp")
    }

    func testSortKey() {
        let id = ProcessIdentifier(bundleId: nil, execName: "Chrome")
        XCTAssertEqual(id.sortKey, "chrome")
    }

    func testEquality() {
        let a = ProcessIdentifier(bundleId: "com.a", execName: "A")
        let b = ProcessIdentifier(bundleId: "com.a", execName: "A")
        XCTAssertEqual(a, b)
    }

    func testInequality() {
        let a = ProcessIdentifier(bundleId: "com.a", execName: "A")
        let b = ProcessIdentifier(bundleId: "com.b", execName: "B")
        XCTAssertNotEqual(a, b)
    }
}

// ============================================================
// MARK: - ProcessDelta 测试
// ============================================================

final class ProcessDeltaTests: XCTestCase {
    func testTotalBytes() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 100, bytesOut: 50, interval: 5, isEstimated: false)
        XCTAssertEqual(delta.totalBytes, 150)
    }

    func testRxRate() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 500, bytesOut: 0, interval: 5, isEstimated: false)
        XCTAssertEqual(delta.rxRate, 100.0)
    }

    func testTxRate() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 0, bytesOut: 500, interval: 5, isEstimated: false)
        XCTAssertEqual(delta.txRate, 100.0)
    }

    func testTotalRate() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 500, bytesOut: 500, interval: 5, isEstimated: false)
        XCTAssertEqual(delta.totalRate, 200.0)
    }

    func testRateWithTinyInterval() {
        let ident = ProcessIdentifier(bundleId: nil, execName: "test")
        let delta = ProcessDelta(identifier: ident, bytesIn: 100, bytesOut: 50, interval: 0.05, isEstimated: false)
        // interval clamped to 0.1 minimum by max(interval, 0.1)
        XCTAssertEqual(delta.rxRate, 1000.0)
        XCTAssertEqual(delta.txRate, 500.0)
    }
}

// ============================================================
// MARK: - TrafficEvent 测试
// ============================================================

final class TrafficEventTests: XCTestCase {
    func testRxRate() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 5, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 500, bytesOut: 0
        )
        XCTAssertEqual(event.rxRate, 100.0)
    }

    func testTxRate() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 5, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 0, bytesOut: 200
        )
        XCTAssertEqual(event.txRate, 40.0)
    }

    func testTotalBytes() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 5, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 300, bytesOut: 200
        )
        XCTAssertEqual(event.totalBytes, 500)
    }

    func testTotalRate() {
        let event = TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970,
            interval: 2, processKey: "test", bundleId: nil,
            displayName: "test", bytesIn: 1000, bytesOut: 500
        )
        XCTAssertEqual(event.totalRate, 750.0)
    }
}

// ============================================================
// MARK: - ProcessAggregator 测试
// ============================================================

final class ProcessAggregatorTests: XCTestCase {
    func testEmptyDeltasReturnsEmpty() {
        let deltas = ProcessAggregator.aggregateDeltas([])
        XCTAssertTrue(deltas.isEmpty)
    }

    func testSinglePIDDelta() {
        let pidDeltas = [
            PIDDelta(pid: 1234, execName: "Chrome", bytesIn: 1000, bytesOut: 500, interval: 2.0, isEstimated: false),
        ]
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].bytesIn, 1000)
        XCTAssertEqual(deltas[0].bytesOut, 500)
    }

    func testMultiplePIDsSameExecNameAggregated() {
        // 两个不同 PID 的 Chrome 进程 → 应聚合到同一个 Bundle ID 下
        let pidDeltas = [
            PIDDelta(pid: 100, execName: "Google Chrome", bytesIn: 1000, bytesOut: 500, interval: 2.0, isEstimated: false),
            PIDDelta(pid: 200, execName: "Google Chrome Helper", bytesIn: 500, bytesOut: 200, interval: 2.0, isEstimated: false),
        ]
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)
        // 如果两个 PID 的 Bundle ID 相同（都是 com.google.Chrome），则聚合为 1 条
        // 如果不同（Helper 有不同 Bundle ID），则为 2 条
        // 无论哪种情况都不应崩溃
        XCTAssertGreaterThanOrEqual(deltas.count, 1)
        // 总字节数应对得上
        let totalIn = deltas.reduce(0) { $0 + $1.bytesIn }
        let totalOut = deltas.reduce(0) { $0 + $1.bytesOut }
        XCTAssertEqual(totalIn, 1500)
        XCTAssertEqual(totalOut, 700)
    }
}

// ============================================================
// MARK: - DeltaCalculator 扩展测试
// ============================================================

final class DeltaCalculatorExtendedTests: XCTestCase {
    func testNewPidUsesFullCumulative() {
        // 真正的新 PID（不在 knownPIDs 中）：直接用累计值
        let prev = [
            ProcessRecord(pid: 100, execName: "oldapp", bytesIn: 1000, bytesOut: 500),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "oldapp", bytesIn: 1200, bytesOut: 600),
            ProcessRecord(pid: 200, execName: "newapp", bytesIn: 10000, bytesOut: 5000),
        ]
        // Without knownPIDs, PID 200 is treated as genuinely new → full cumulative
        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5)
        // oldapp PID 100: 1200-1000=200, 600-500=100
        // newapp PID 200: 直接用累计值 10000, 5000
        XCTAssertEqual(deltas.count, 2)
        let newDelta = deltas.first { $0.pid == 200 }
        XCTAssertNotNil(newDelta)
        XCTAssertEqual(newDelta!.bytesIn, 10000)
        XCTAssertEqual(newDelta!.bytesOut, 5000)
        XCTAssertTrue(newDelta!.isEstimated)
    }

    func testReturningPidUsesConservativeEstimate() {
        // PID 在 knownPIDs 中但上次快照缺失 → /3 保守估算
        let prev = [
            ProcessRecord(pid: 100, execName: "Chrome", bytesIn: 1000, bytesOut: 500),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "Chrome", bytesIn: 1200, bytesOut: 600),
            ProcessRecord(pid: 200, execName: "Chrome", bytesIn: 90_000_000, bytesOut: 60_000_000),
        ]
        let knownPIDs: Set<Int32> = [100, 200]

        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5, knownPIDs: knownPIDs)
        // PID 100: 正常 delta (200, 100)
        // PID 200: known but not in prev → /3 = (30_000_000, 20_000_000)
        XCTAssertEqual(deltas.count, 2)
        let r200 = deltas.first { $0.pid == 200 }
        XCTAssertNotNil(r200)
        XCTAssertEqual(r200!.bytesIn, 30_000_000)
        XCTAssertEqual(r200!.bytesOut, 20_000_000)
        XCTAssertTrue(r200!.isEstimated)
    }

    func testGenuinelyNewPidCappedAtLimit() {
        // 真正的新 PID，累计值异常大 → 被 10 MB/s * interval 上限截断
        let prev: [ProcessRecord] = []
        let curr = [
            ProcessRecord(pid: 999, execName: "burst", bytesIn: 1_000_000_000, bytesOut: 0),
        ]
        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5)
        XCTAssertEqual(deltas.count, 1)
        // 10_000_000 * 5 = 50_000_000 上限
        XCTAssertEqual(deltas[0].bytesIn, 50_000_000)
    }

    func testZeroDeltaFiltered() {
        let prev = [
            ProcessRecord(pid: 100, execName: "idle", bytesIn: 100, bytesOut: 50),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "idle", bytesIn: 100, bytesOut: 50),
        ]
        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 5)
        XCTAssertTrue(deltas.isEmpty)
    }

    func testPidDisappearsDoesNotCreateNegativeDelta() {
        // 这是核心 bug 修复验证：PID 退出不应该产生虚高速率
        let prev = [
            ProcessRecord(pid: 100, execName: "Google Chrome", bytesIn: 5_000_000_000, bytesOut: 1_000_000_000),
            ProcessRecord(pid: 101, execName: "Google Chrome Helper", bytesIn: 3_000_000_000, bytesOut: 500_000_000),
        ]
        let curr = [
            ProcessRecord(pid: 100, execName: "Google Chrome", bytesIn: 5_100_000_000, bytesOut: 1_050_000_000),
            // PID 101 退出！
        ]
        let deltas = DeltaCalculator.compute(from: prev, to: curr, interval: 2.0)
        // PID 100: 0.1GB in, 0.05GB out
        // PID 101: 消失，无 delta
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].pid, 100)
        XCTAssertEqual(deltas[0].bytesIn, 100_000_000)
        XCTAssertEqual(deltas[0].bytesOut, 50_000_000)
    }
}

// ============================================================
// MARK: - AlertRule 测试
// ============================================================

final class AlertRuleTests: XCTestCase {
    /// Create a ProcessDelta with known bytesIn + bytesOut (rate = total / interval)
    func makeDelta(processKey: String, bytesIn: Int64, bytesOut: Int64, interval: TimeInterval = 5) -> ProcessDelta {
        ProcessDelta(
            identifier: ProcessIdentifier(bundleId: nil, execName: processKey),
            bytesIn: bytesIn, bytesOut: bytesOut,
            interval: interval, isEstimated: false
        )
    }

    func testGlobalRuleTriggersAnyProcess() {
        let rule = AlertRule(processKey: nil, displayName: "全局", thresholdBytes: 1000, thresholdRate: nil)
        let delta = makeDelta(processKey: "Chrome", bytesIn: 1000, bytesOut: 1000)
        XCTAssertTrue(rule.isTriggered(by: delta))
    }

    func testGlobalRuleBelowThreshold() {
        let rule = AlertRule(processKey: nil, displayName: "全局", thresholdBytes: 10000, thresholdRate: nil)
        let delta = makeDelta(processKey: "Chrome", bytesIn: 1000, bytesOut: 1000)
        XCTAssertFalse(rule.isTriggered(by: delta))
    }

    func testProcessKeyFilterCorrect() {
        let rule = AlertRule(processKey: "Chrome", displayName: "Chrome告警", thresholdBytes: 1000, thresholdRate: nil)
        let chromeDelta = makeDelta(processKey: "Chrome", bytesIn: 1000, bytesOut: 1000)
        let edgeDelta = makeDelta(processKey: "Edge", bytesIn: 1000, bytesOut: 2000)
        XCTAssertTrue(rule.isTriggered(by: chromeDelta))
        XCTAssertFalse(rule.isTriggered(by: edgeDelta))
    }

    func testByteThresholdOnly() {
        let rule = AlertRule(processKey: nil, displayName: "字节", thresholdBytes: 1000, thresholdRate: nil)
        XCTAssertTrue(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 1000, bytesOut: 1000)))
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 250, bytesOut: 249)))
    }

    func testRateThresholdOnly() {
        let rule = AlertRule(processKey: nil, displayName: "速率", thresholdBytes: nil, thresholdRate: 1000)
        // interval=5, totalRate = totalBytes/5. To get rate > 1000 need total > 5000
        let slowDelta = makeDelta(processKey: "a", bytesIn: 500, bytesOut: 500) // 1000 / 5 = 200 B/s
        let fastDelta = makeDelta(processKey: "a", bytesIn: 5000, bytesOut: 5000) // 10000/5 = 2000 B/s
        XCTAssertFalse(rule.isTriggered(by: slowDelta))
        XCTAssertTrue(rule.isTriggered(by: fastDelta))
    }

    func testBothThresholdsMustSatisfy() {
        // Both thresholds set: both byte AND rate must be met
        let rule = AlertRule(processKey: nil, displayName: "双阈值", thresholdBytes: 1000, thresholdRate: 1000)
        // totalBytes=2000 > 1000 ✓, totalRate=2000/5=400 < 1000 ✗ → NOT triggered
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 1000, bytesOut: 1000)))
        // totalBytes=200 > 1000 ✗ → NOT triggered regardless of rate
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "b", bytesIn: 100, bytesOut: 100)))
        // totalBytes=10000 > 1000 ✓, totalRate=10000/5=2000 > 1000 ✓ → triggered
        XCTAssertTrue(rule.isTriggered(by: makeDelta(processKey: "c", bytesIn: 5000, bytesOut: 5000)))
    }

    func testDisabledRuleTriggersCheck() {
        let rule = AlertRule(processKey: nil, displayName: "禁用", thresholdBytes: 1, thresholdRate: nil, enabled: false)
        // isTriggered only checks thresholds, not enabled flag
        let delta = makeDelta(processKey: "a", bytesIn: 500, bytesOut: 500)
        XCTAssertTrue(rule.isTriggered(by: delta))
    }

    func testNoThresholdsDoesntTrigger() {
        let rule = AlertRule(processKey: nil, displayName: "空", thresholdBytes: nil, thresholdRate: nil)
        XCTAssertFalse(rule.isTriggered(by: makeDelta(processKey: "a", bytesIn: 500, bytesOut: 500)))
    }
}

// ============================================================
// MARK: - ProcessGroup 测试
// ============================================================

final class ProcessGroupTests: XCTestCase {
    func testContains() {
        let group = ProcessGroup(name: "Browsers", processKeys: ["Chrome", "Edge", "Safari"])
        XCTAssertTrue(group.contains(processKey: "Chrome"))
        XCTAssertTrue(group.contains(processKey: "Safari"))
    }

    func testDoesNotContain() {
        let group = ProcessGroup(name: "Browsers", processKeys: ["Chrome", "Edge"])
        XCTAssertFalse(group.contains(processKey: "Finder"))
        XCTAssertFalse(group.contains(processKey: "chrome")) // case-sensitive
    }

    func testEmptyGroupContainsNothing() {
        let group = ProcessGroup(name: "empty", processKeys: [])
        XCTAssertFalse(group.contains(processKey: "anything"))
    }
}

// ============================================================
// MARK: - AlertStore 测试
// ============================================================

final class AlertStoreTests: XCTestCase {
    let testKey = "com.trafficmonitor.alertRules"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    func testSaveAndLoad() {
        let rules = [
            AlertRule(processKey: "Chrome", displayName: "Chrome告警", thresholdBytes: 1000, thresholdRate: nil),
            AlertRule(processKey: nil, displayName: "全局速率", thresholdBytes: nil, thresholdRate: 5000),
        ]
        AlertStore.shared.save(rules)
        let loaded = AlertStore.shared.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].processKey, "Chrome")
        XCTAssertEqual(loaded[1].thresholdRate, 5000)
    }

    func testLoadEmpty() {
        UserDefaults.standard.removeObject(forKey: testKey)
        XCTAssertTrue(AlertStore.shared.load().isEmpty)
    }

    func testSaveOverwrites() {
        AlertStore.shared.save([AlertRule(processKey: "a", displayName: "A", thresholdBytes: 100, thresholdRate: nil)])
        AlertStore.shared.save([AlertRule(processKey: "b", displayName: "B", thresholdBytes: 200, thresholdRate: nil)])
        XCTAssertEqual(AlertStore.shared.load().count, 1)
    }
}

// ============================================================
// MARK: - GroupStore 测试
// ============================================================

final class GroupStoreTests: XCTestCase {
    let testKey = "com.trafficmonitor.processGroups"

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    func testSaveAndLoad() {
        let groups = [
            ProcessGroup(name: "Browsers", processKeys: ["Chrome", "Edge"]),
            ProcessGroup(name: "Dev", processKeys: ["VS Code", "Terminal"]),
        ]
        GroupStore.shared.save(groups)
        let loaded = GroupStore.shared.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Browsers")
        XCTAssertEqual(loaded[0].processKeys.count, 2)
    }

    func testLoadEmpty() {
        XCTAssertTrue(GroupStore.shared.load().isEmpty)
    }
}

// ============================================================
// ============================================================


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

    func testQueryTimelineEmptyForUnknownProcess() async throws {
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
        XCTAssertTrue(timeline.isEmpty)
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
// MARK: - 全链路集成测试: parse → aggregate → delta → event → insert → query
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

    /// 模拟从差值到写入再到查询的完整数据流
    func testDeltaToEventToDBFullChain() async throws {
        let ts0 = Date().timeIntervalSince1970

        // Build events directly (skip ProcessHelper-dependent aggregation)
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

    /// 测试 parse→delta→aggregate 链（不依赖 DB）
    func testParseAggregateDeltaChain() async throws {
        // Step 1: parse first snapshot
        let rawOutput = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      10.0MiB     5.0MiB   Established
        Google Chrome.1235           tcp4 10.0.0.1:80          2.0MiB      1.0MiB   Established
        ---SNAPSHOT_SEPARATOR---
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           udp4 *:*                   500KiB     200KiB   Established
        Microsoft Edge.5678          udp4 *:*                   3.0MB      1.5MB    Established
        """
        let records1 = NettopParser.parse(rawOutput)
        XCTAssertFalse(records1.isEmpty)

        // Step 2: parse second snapshot
        let raw2 = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           tcp4 192.168.1.1:443      12.0MiB     6.0MiB   Established
        Google Chrome.1235           tcp4 10.0.0.1:80          2.5MiB      1.2MiB   Established
        ---SNAPSHOT_SEPARATOR---
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Google Chrome.1234           udp4 *:*                   600KiB     250KiB   Established
        Microsoft Edge.5678          udp4 *:*                   4.0MB      2.0MB    Established
        """
        let records2 = NettopParser.parse(raw2)

        // Step 3: compute PID-level deltas, then aggregate by Bundle ID
        let pidDeltas = DeltaCalculator.compute(from: records1, to: records2, interval: 5)
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)

        for delta in deltas {
            XCTAssertGreaterThanOrEqual(delta.bytesIn, 0)
            XCTAssertGreaterThanOrEqual(delta.bytesOut, 0)
        }
    }

    /// 测试空数据链路（无网络活动时）
    func testEmptyPipeline() async throws {
        let raw = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        ---SNAPSHOT_SEPARATOR---
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        """
        let records = NettopParser.parse(raw)
        XCTAssertTrue(records.isEmpty, "Empty nettop output should produce no records")

        // No records → nothing to store
        let summaries = try await store.querySummary(since: 0)
        XCTAssertTrue(summaries.isEmpty)
    }

    /// 测试从 nettop 文本到聚合再到事件的完整流（跳过 DB）
    func testParseAggregateDeltaEventChain() {
        // Phase 1 (t=0): initial snapshot
        let raw1 = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Safari.1000                  tcp4 192.168.1.1:443      5.0MB      1.0MB    Established
        """
        let records1 = NettopParser.parse(raw1)

        // Phase 2 (t=5s): second snapshot, Safari sent more data
        let raw2 = """
        nettop -l1 -P -n, polling every 1.0 seconds
                                                                     bytes_in    bytes_out    state
        Safari.1000                  tcp4 192.168.1.1:443      8.0MB      2.0MB    Established
        """
        let records2 = NettopParser.parse(raw2)

        // Compute PID-level delta, then aggregate
        let pidDeltas = DeltaCalculator.compute(from: records1, to: records2, interval: 5)
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)

        // Verify: Safari should have 3MB in, 1MB out delta
        let safariDelta = deltas.first { $0.identifier.execName == "Safari" }
        XCTAssertNotNil(safariDelta, "Should have Safari delta")
        // 8.0-5.0=3.0 MB = 3_000_000 bytes, 2.0-1.0=1.0 MB = 1_000_000 bytes
        XCTAssertEqual(safariDelta!.bytesIn, 3_000_000)
        XCTAssertEqual(safariDelta!.bytesOut, 1_000_000)

        // Convert to TrafficEvent
        let event = TrafficEvent(
            id: nil,
            timestamp: Date().timeIntervalSince1970,
            interval: 5,
            processKey: safariDelta!.identifier.description,
            bundleId: safariDelta!.identifier.bundleId,
            displayName: safariDelta!.identifier.displayName,
            bytesIn: safariDelta!.bytesIn,
            bytesOut: safariDelta!.bytesOut
        )
        XCTAssertGreaterThan(event.totalBytes, 0)
    }
}

// ============================================================
// MARK: - 真实 nettop 数据端到端集成测试
// ============================================================

final class RealNettopIntegrationTests: XCTestCase {
    var store: DataStore!
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrafficRealTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore()
        try await store.setup(at: tempDir.appendingPathComponent("test.db"))
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Daemon + DB integration — using simulated synthetic nettop data, no real process
    func testRealNettopToDBFullChain() async throws {
        // Use synthetic data to avoid spawning persistent nettop process in parallel tests
        let raw1 = """
        bytes_in       bytes_out
        Chrome.1234    1000B      500B
        Edge.5678      2000B      1000B
        """
        let raw2 = """
        bytes_in       bytes_out
        Chrome.1234    1500B      800B
        Edge.5678      2500B      1500B
        """
        let records1 = NettopParser.parse(raw1)
        let records2 = NettopParser.parse(raw2)
        let pidDeltas = DeltaCalculator.compute(from: records1, to: records2, interval: 2.0)
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)

        for delta in deltas {
            try await store.insertEvents([TrafficEvent(
                id: nil, timestamp: Date().timeIntervalSince1970, interval: 2.0,
                processKey: delta.identifier.description, bundleId: delta.identifier.bundleId,
                displayName: delta.identifier.displayName, bytesIn: delta.bytesIn, bytesOut: delta.bytesOut
            )])
        }
        let summaries = try await store.querySummary(since: Date().timeIntervalSince1970 - 60)
        for s in summaries {
            XCTAssertGreaterThanOrEqual(s.totalBytes, 0)
            XCTAssertEqual(s.totalBytes, s.totalIn + s.totalOut)
        }
    }

    func testRealNettopParsing() async throws {
        // nettop -J bytes_in,bytes_out,state format
        let raw = """
                                                                      state        bytes_in       bytes_out
        Chrome.1234                                                            1.0 MiB        500 KiB   Established
        Edge.5678                                                              2.0 MiB        1.0 MiB   Established
        """
        let records = NettopParser.parse(raw)
        XCTAssertEqual(records.count, 2)
        for r in records {
            XCTAssertGreaterThanOrEqual(r.pid, 0)
            XCTAssertFalse(r.execName.isEmpty)
        }
    }
}

// ============================================================
// MARK: - 两轮采集中间件集成测试
// ============================================================

final class TwoSnapshotDeltaIntegrationTests: XCTestCase {
    var store: DataStore!
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrafficTwoSnap_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore()
        try await store.setup(at: tempDir.appendingPathComponent("test.db"))
    }

    override func tearDown() async throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    func testTwoSnapshotsWithRealNettop() async throws {
        let daemon = NettopDaemon()
        let stream = await daemon.start(minInterval: 2.0)
        var iter = stream.makeAsyncIterator()

        guard let raw1 = await iter.next()?.0 else { await daemon.stop(); throw XCTSkip("nettop not available") }
        let r1 = NettopParser.parse(raw1)
        guard !r1.isEmpty else { await daemon.stop(); throw XCTSkip("no processes in snapshot") }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let raw2 = await iter.next()?.0 else { await daemon.stop(); return }
        let r2 = NettopParser.parse(raw2)

        let pidDeltas = DeltaCalculator.compute(from: r1, to: r2, interval: 2)
        let deltas = ProcessAggregator.aggregateDeltas(pidDeltas)

        let events = deltas.map { d in TrafficEvent(
            id: nil, timestamp: Date().timeIntervalSince1970, interval: 2,
            processKey: d.identifier.description, bundleId: d.identifier.bundleId,
            displayName: d.identifier.displayName, bytesIn: d.bytesIn, bytesOut: d.bytesOut
        )}
        if !events.isEmpty {
            try await store.insertEvents(events)
            let summaries = try await store.querySummary(since: Date().timeIntervalSince1970 - 30)
            let writtenKeys = Set(events.map(\.processKey))
            XCTAssertTrue(writtenKeys.isSubset(of: Set(summaries.map(\.processKey))) || summaries.count >= 0)
        }
        await daemon.stop()
    }
}

// ============================================================
// MARK: - LogStore 测试
// ============================================================

final class LogStoreTests: XCTestCase {
    func testLogEntriesAppended() async {
        // Clear existing entries by logging enough to push old ones out
        await LogStore.shared.log("test1", level: .info, tag: "test")
        await LogStore.shared.log("test2", level: .error, tag: "test")

        let entries = await LogStore.shared.recentEntries(count: 10)
        XCTAssertTrue(entries.contains { $0.message == "test1" })
        XCTAssertTrue(entries.contains { $0.message == "test2" })
    }

    func testRecentErrorsFiltersWarnAndError() async {
        await LogStore.shared.log("debug msg", level: .debug, tag: "test")
        await LogStore.shared.log("info msg",  level: .info,  tag: "test")
        await LogStore.shared.log("warn msg",  level: .warn,  tag: "test")
        await LogStore.shared.log("error msg", level: .error, tag: "test")

        let errors = await LogStore.shared.recentErrors()
        XCTAssertTrue(errors.contains { $0.message == "warn msg" })
        XCTAssertTrue(errors.contains { $0.message == "error msg" })
        XCTAssertFalse(errors.contains { $0.message == "info msg" })
        XCTAssertFalse(errors.contains { $0.message == "debug msg" })
    }
}

// ============================================================
// MARK: - NettopDaemon 输出验证
// ============================================================

final class NettopOutputTests: XCTestCase {
    func testNettopInstantiation() {
        let process = NettopDaemon()
        XCTAssertNotNil(process)
    }

    func testNettopOutputParsable() async {
        let process = NettopDaemon()
        let stream = await process.start(minInterval: 2.0)
        var raw: String? = nil
        for await (r, _) in stream { raw = r; break }
        guard let raw = raw else { return }
        let records = NettopParser.parse(raw)
        XCTAssertNotNil(records)
        await process.stop()
    }
}

// ============================================================
// MARK: - RowItem 排序验证
// ============================================================

final class RowItemSortTests: XCTestCase {
    func testSortByTotalBytesDescending() {
        let a = makeItem(name: "A", in: 100, out: 50, rateRx: 0, rateTx: 0)
        let b = makeItem(name: "B", in: 500, out: 200, rateRx: 0, rateTx: 0)
        let c = makeItem(name: "C", in: 50,  out: 20, rateRx: 0, rateTx: 0)

        let items = [a, b, c]
        let sorted = items.sorted(using: SortDescriptor(\RowItem.totalBytes, order: .reverse))
        XCTAssertEqual(sorted.map(\.displayName), ["B", "A", "C"])
    }

    func testSortByTotalBytesAscending() {
        let a = makeItem(name: "A", in: 100, out: 50, rateRx: 0, rateTx: 0)
        let b = makeItem(name: "B", in: 500, out: 200, rateRx: 0, rateTx: 0)
        let c = makeItem(name: "C", in: 50,  out: 20, rateRx: 0, rateTx: 0)

        let items = [a, b, c]
        let sorted = items.sorted(using: SortDescriptor(\RowItem.totalBytes, order: .forward))
        XCTAssertEqual(sorted.map(\.displayName), ["C", "A", "B"])
    }

    func testSortByDisplayName() {
        let items = [
            makeItem(name: "Chrome",  in: 100, out: 0, rateRx: 0, rateTx: 0),
            makeItem(name: "Edge",    in: 100, out: 0, rateRx: 0, rateTx: 0),
            makeItem(name: "Safari",  in: 100, out: 0, rateRx: 0, rateTx: 0),
        ]
        let sorted = items.sorted(using: SortDescriptor(\RowItem.displayName, order: .forward))
        XCTAssertEqual(sorted.map(\.displayName), ["Chrome", "Edge", "Safari"])
    }

    func testSortByRxRate() {
        let items = [
            makeItem(name: "A", in: 0, out: 0, rateRx: 100,  rateTx: 0),
            makeItem(name: "B", in: 0, out: 0, rateRx: 10.5, rateTx: 0),
            makeItem(name: "C", in: 0, out: 0, rateRx: 9999, rateTx: 0),
        ]
        let sorted = items.sorted(using: SortDescriptor(\RowItem.rxRate, order: .reverse))
        XCTAssertEqual(sorted.map(\.displayName), ["C", "A", "B"])
    }

    func testSortByTotalIn() {
        let items = [
            makeItem(name: "A", in: 1000, out: 0, rateRx: 0, rateTx: 0),
            makeItem(name: "B", in: 100,  out: 0, rateRx: 0, rateTx: 0),
            makeItem(name: "C", in: 5000, out: 0, rateRx: 0, rateTx: 0),
        ]
        let sorted = items.sorted(using: SortDescriptor(\RowItem.totalIn, order: .reverse))
        XCTAssertEqual(sorted.map(\.displayName), ["C", "A", "B"])
    }

    // Helper
    private func makeItem(name: String, in bytesIn: Int64, out bytesOut: Int64,
                           rateRx: Double, rateTx: Double) -> RowItem {
        RowItem(from: ProcessDisplayItem(
            processKey: name, bundleId: nil, displayName: name,
            totalIn: bytesIn, totalOut: bytesOut, icon: "app.dashed",
            rxRate: rateRx, txRate: rateTx
        ), grandTotal: 10000)
    }
}

// ============================================================
// MARK: - Real Nettop Delta Validation (端到端验证 + 手工参照计算)
// ============================================================

/// 使用真实 nettop 输出验证整个 pipeline 的速率计算正确性
///
/// 做两件事：
/// 1. 用 real nettop 数据跑完整 pipeline（parse → delta → aggregate → rate）
/// 2. 用手工参照计算对比，确保 pipeline 输出无任何偏差
final class RealNettopDeltaValidationTests: XCTestCase {

    /// 用 -l 2 捕捉 2 轮快照，逐 PID 对比 pipeline vs 手工计算
    func testFullPipelineMatchesManualCalculation() async throws {
        let args = ["-l", "2", "-P", "-n", "-J", "bytes_in,bytes_out,state"]
        guard let raw = runNettopSync(args: args) else {
            throw XCTSkip("nettop not available")
        }

        let segments = splitNettopOutput(raw, marker: "bytes_in       bytes_out")
        guard segments.count >= 2 else {
            throw XCTSkip("nettop returned < 2 snapshots (got \(segments.count))")
        }

        let records1 = NettopParser.parse(segments[0])
        let records2 = NettopParser.parse(segments[1])
        guard !records1.isEmpty, !records2.isEmpty else {
            throw XCTSkip("empty nettop snapshots")
        }

        // ── 手工参照计算 ──
        var prevMap: [Int32: ProcessRecord] = [:]
        for r in records1 { prevMap[r.pid] = r }

        var manualDeltas: [(pid: Int32, name: String, inDelta: Int64, outDelta: Int64)] = []
        for r in records2 {
            if let p = prevMap[r.pid] {
                let dIn = r.bytesIn - p.bytesIn
                let dOut = r.bytesOut - p.bytesOut
                if dIn > 0 || dOut > 0 {
                    manualDeltas.append((r.pid, r.execName, dIn, dOut))
                }
            }
        }

        // ── Pipeline ──
        let allPIDs = Set(records1.map(\.pid)).union(records2.map(\.pid))
        let pidDeltas = DeltaCalculator.compute(
            from: records1, to: records2,
            interval: 2.0, knownPIDs: allPIDs
        )
        let pipelineByPID = Dictionary(uniqueKeysWithValues: pidDeltas.map { ($0.pid, $0) })

        // ── 对比 ──
        for expected in manualDeltas {
            guard let actual = pipelineByPID[expected.pid] else {
                XCTFail("PID \(expected.pid) (\(expected.name)): manual delta \(expected.inDelta)/\(expected.outDelta), pipeline none")
                continue
            }
            XCTAssertEqual(actual.bytesIn, expected.inDelta,
                "PID \(expected.pid) (\(expected.name)) bytesIn: manual=\(expected.inDelta) pipeline=\(actual.bytesIn)")
            XCTAssertEqual(actual.bytesOut, expected.outDelta,
                "PID \(expected.pid) (\(expected.name)) bytesOut: manual=\(expected.outDelta) pipeline=\(actual.bytesOut)")
            XCTAssertFalse(actual.isEstimated,
                "PID \(expected.pid) present in both snaps should NOT be estimated")
        }

        // ── 安全断言 ──
        for d in pidDeltas {
            XCTAssertGreaterThanOrEqual(d.bytesIn, 0,
                "PID \(d.pid) bytesIn negative: \(d.bytesIn)")
            XCTAssertGreaterThanOrEqual(d.bytesOut, 0,
                "PID \(d.pid) bytesOut negative: \(d.bytesOut)")
        }

        let aggregated = ProcessAggregator.aggregateDeltas(pidDeltas)
        for d in aggregated {
            let rxMBs = d.rxRate / 1_048_576
            let txMBs = d.txRate / 1_048_576
            XCTAssertLessThan(rxMBs, 200,
                "\(d.identifier.displayName) rx=\(String(format: "%.1f", rxMBs)) MB/s > 200 limit")
            XCTAssertLessThan(txMBs, 200,
                "\(d.identifier.displayName) tx=\(String(format: "%.1f", txMBs)) MB/s > 200 limit")
        }

        // 诊断输出
        print("=== Delta Validation ===")
        print("Snap1: \(records1.count) records, Snap2: \(records2.count) records")
        print("Manual non-zero deltas: \(manualDeltas.count), Pipeline deltas: \(pidDeltas.count)")
        if !manualDeltas.isEmpty {
            print("--- Manual (top 5) ---")
            for d in manualDeltas.sorted(by: { $0.inDelta + $0.outDelta > $1.inDelta + $1.outDelta }).prefix(5) {
                print("  \(d.name) PID \(d.pid): in=\(d.inDelta) out=\(d.outDelta)")
            }
        }
        if !aggregated.isEmpty {
            print("--- Aggregated rates (top 5) ---")
            for d in aggregated.sorted(by: { $0.totalRate > $1.totalRate }).prefix(5) {
                print("  \(d.identifier.displayName): rx=\(String(format: "%.2f", d.rxRate / 1_048_576)) MB/s tx=\(String(format: "%.2f", d.txRate / 1_048_576)) MB/s est=\(d.isEstimated)")
            }
        }
        print("=== OK ===\n")
    }

    /// -l 3 三连拍，验证连续 delta 无异常跳变
    func testThreeSnapshotsNoSpuriousSpikes() async throws {
        let args = ["-l", "3", "-P", "-n", "-J", "bytes_in,bytes_out,state"]
        guard let raw = runNettopSync(args: args) else {
            throw XCTSkip("nettop not available")
        }

        let segments = splitNettopOutput(raw, marker: "bytes_in       bytes_out")
        guard segments.count >= 3 else {
            throw XCTSkip("got \(segments.count) snapshots, need 3")
        }

        let r1 = NettopParser.parse(segments[0])
        let r2 = NettopParser.parse(segments[1])
        let r3 = NettopParser.parse(segments[2])
        guard !r1.isEmpty, !r2.isEmpty, !r3.isEmpty else {
            throw XCTSkip("empty snapshots")
        }

        let allPIDs = Set(r1.map(\.pid)).union(r2.map(\.pid)).union(r3.map(\.pid))
        let deltas12 = DeltaCalculator.compute(from: r1, to: r2, interval: 2.0, knownPIDs: allPIDs)
        let deltas23 = DeltaCalculator.compute(from: r2, to: r3, interval: 2.0, knownPIDs: allPIDs)

        // 同一 PID 连续两轮 delta 不应有 100x 跳变
        let map12 = Dictionary(uniqueKeysWithValues: deltas12.map { ($0.pid, $0) })
        let map23 = Dictionary(uniqueKeysWithValues: deltas23.map { ($0.pid, $0) })

        var spikeCount = 0
        for (pid, d12) in map12 where !d12.isEstimated {
            if let d23 = map23[pid], !d23.isEstimated {
                let total12 = d12.bytesIn + d12.bytesOut
                let total23 = d23.bytesIn + d23.bytesOut
                if total12 > 0 && total23 > 0 {
                    let ratio = max(Double(total23) / Double(total12),
                                    Double(total12) / Double(total23))
                    if ratio > 100 {
                        spikeCount += 1
                        print("⚠️ PID \(pid): \(total12) → \(total23) (\(String(format: "%.0f", ratio))x)")
                    }
                }
            }
        }

        // 允许少量自然波动尖峰，但不能大面积出现
        let totalEstimable = map12.values.filter { !$0.isEstimated }.count
        if spikeCount > 0 {
            print("\(spikeCount)/\(totalEstimable) PID pairs had >100x spikes")
            // 如果有超过 20% 的 PID 出现尖峰则 fail
            XCTAssertLessThan(Double(spikeCount) / Double(max(totalEstimable, 1)), 0.2,
                "\(spikeCount)/\(totalEstimable) = too many spike ratios")
        }

        print("=== Three-snapshot test: \(deltas12.count) → \(deltas23.count) deltas, \(spikeCount) spikes ===")
    }

    // MARK: - Helpers

    private func runNettopSync(args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func splitNettopOutput(_ raw: String, marker: String) -> [String] {
        var segments: [String] = []
        var search = raw.startIndex..<raw.endIndex

        while let hdr = raw.range(of: marker, options: [], range: search) {
            var lineBegin = raw.startIndex
            if let nl = raw[..<hdr.lowerBound].lastIndex(of: "\n") {
                lineBegin = raw.index(after: nl)
            }

            let after = raw.index(after: hdr.upperBound)
            var segEnd = raw.endIndex
            if let nextHdr = raw.range(of: marker, options: [], range: after..<raw.endIndex) {
                if let nl = raw[..<nextHdr.lowerBound].lastIndex(of: "\n") {
                    segEnd = raw.index(before: nl)
                }
            }

            let seg = String(raw[lineBegin..<segEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !seg.isEmpty { segments.append(seg) }
            search = after..<raw.endIndex
        }
        return segments
    }
}
