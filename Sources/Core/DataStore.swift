import Foundation
import GRDB

/// 数据存储层（GRDB 封装）
///
/// 单例，负责 SQLite 初始化、写入流量事件、查询统计数据。
actor DataStore {
    static let shared = DataStore()

    private var dbWriter: DatabaseWriter?
    private var isSetup = false
    private var currentDBPath: String?

    init() {}

    // MARK: - Setup

    /// 初始化数据库（首次使用时调用，后续调用无副作用）
    func setup() throws {
        try setup(at: Constants.databaseURL)
    }

    /// 使用自定义路径初始化数据库（用于测试或自定义部署）
    func setup(at dbURL: URL) throws {
        guard !isSetup else { return }
        isSetup = true
        currentDBPath = dbURL.path

        // 确保目录存在
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        print("[DataStore] Opening database at \(dbURL.path)")

        let writer = try DatabasePool(path: dbURL.path)

        // 创建表
        try writer.write { db in
            try db.create(table: "trafficEvent", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull().indexed()
                t.column("interval", .double).notNull()
                t.column("processKey", .text).notNull().indexed()
                t.column("bundleId", .text)
                t.column("displayName", .text).notNull()
                t.column("bytesIn", .integer).notNull()
                t.column("bytesOut", .integer).notNull()
            }

            // 复合索引：按时间 + 进程查
            try db.create(index: "idx_traffic_ts_process",
                          on: "trafficEvent",
                          columns: ["timestamp", "processKey"],
                          ifNotExists: true)
        }

        dbWriter = writer
    }

    // MARK: - Write

    /// 批量插入流量事件
    ///
    /// 用单条多值 `INSERT ... VALUES (?,...),(?,...)` 分块写入，
    /// 而不是逐行 `insert`（每行一次 bind + step + 语句复用查找）。
    func insertEvents(_ events: [TrafficEvent]) throws {
        guard let writer = dbWriter, !events.isEmpty else { return }

        try writer.write { db in
            for chunk in stride(from: 0, to: events.count, by: Constants.insertChunkSize) {
                let slice = events[chunk ..< min(chunk + Constants.insertChunkSize, events.count)]
                let placeholders = Array(
                    repeating: "(?,?,?,?,?,?,?)", count: slice.count
                ).joined(separator: ",")
                var args: [DatabaseValueConvertible?] = []
                args.reserveCapacity(slice.count * 7)
                for e in slice {
                    args.append(e.timestamp)
                    args.append(e.interval)
                    args.append(e.processKey)
                    args.append(e.bundleId)
                    args.append(e.displayName)
                    args.append(e.bytesIn)
                    args.append(e.bytesOut)
                }
                try db.execute(
                    sql: """
                        INSERT INTO trafficEvent
                        (timestamp, interval, processKey, bundleId, displayName, bytesIn, bytesOut)
                        VALUES \(placeholders)
                        """,
                    arguments: StatementArguments(args)
                )
            }
        }
    }

    /// 清理超过保留期的明细数据（启动时调用一次）
    func pruneExpired(retentionDays: Double = Constants.retentionDays) throws {
        let cutoff = Date().timeIntervalSince1970 - retentionDays * 86400
        try deleteBefore(cutoff)
    }

    /// 空闲页占比过高时整理数据库文件，把空间还给系统。
    ///
    /// SQLite 删除行只是把页挂到 freelist，文件本身不会缩小 —— 长期运行下
    /// 「删了很多但文件一直很大」。实测某次运行：1531 页里 1159 页是空闲的，
    /// 6 MB 文件只装着 8955 行，**76% 是废弃空间**。
    ///
    /// 不用 `auto_vacuum`：它只能在建库时设定，且会让每次写入都多做页搬移。
    /// 这里改为按需 `VACUUM`，只在浪费确实明显时才做。
    ///
    /// - Returns: 回收的字节数；未达阈值则为 0
    @discardableResult
    func compactIfWasteful(
        minimumFreeRatio: Double = 0.25,
        minimumFreeBytes: Int64 = 1 << 20
    ) throws -> Int64 {
        guard let writer = dbWriter else { return 0 }

        // 先并回 WAL，否则 freelist_count / page_count 反映的是并入前的旧状态
        try checkpoint()

        let (freePages, pageSize) = try writer.read { db -> (Int64, Int64) in
            let free = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let total = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            // 总页为 0 时直接跳过，避免除零
            guard total > 0, Double(free) / Double(total) >= minimumFreeRatio else { return (0, size) }
            return (free, size)
        }

        let reclaimable = freePages * pageSize
        guard reclaimable >= minimumFreeBytes else { return 0 }

        let before = databaseSize()
        // VACUUM 要重写整个文件，不能在事务里跑
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        // VACUUM 本身会往 WAL 里写下整个新库。不再 checkpoint 一次的话，
        // 主库虽然缩了（实测 687 页 → 12 页），WAL 却撑大到比原来还多，
        // 「整理完反而变大」。
        try checkpoint()
        return max(0, before - databaseSize())
    }

    // MARK: - Query

    /// 查询指定时间范围内的流量汇总（按进程聚合）
    ///
    /// - Parameters:
    ///   - since: 起始时间戳
    ///   - until: 结束时间戳
    ///   - limit: 最多返回 N 个进程（0 = 不限）
    /// - Returns: 按总流量降序排列的进程统计
    func querySummary(
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        limit: Int = 0
    ) throws -> [ProcessSummary] {
        guard let writer = dbWriter else { return [] }

        return try writer.read { db in
            var sql = """
                SELECT processKey,
                       bundleId,
                       displayName,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut,
                       COUNT(*)      AS sampleCount,
                       MIN(timestamp) AS firstSeen,
                       MAX(timestamp) AS lastSeen
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY processKey
                ORDER BY (totalIn + totalOut) DESC
            """
            if limit > 0 {
                sql += " LIMIT \(limit)"
            }

            return try Row.fetchAll(db, sql: sql, arguments: [since, until]).map { row in
                ProcessSummary(
                    processKey: row["processKey"],
                    bundleId: row["bundleId"],
                    displayName: row["displayName"],
                    totalIn: row["totalIn"],
                    totalOut: row["totalOut"],
                    sampleCount: row["sampleCount"],
                    firstSeen: row["firstSeen"],
                    lastSeen: row["lastSeen"]
                )
            }
        }
    }

    /// 查询单个进程的时间线数据（按时间桶聚合）
    func queryTimeline(
        processKey: String,
        since: TimeInterval,
        until: TimeInterval = Date().timeIntervalSince1970,
        bucketSeconds: TimeInterval = 300
    ) throws -> [TimelinePoint] {
        guard let writer = dbWriter else { return [] }

        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(timestamp / ? AS INTEGER) * ? AS bucket,
                       SUM(bytesIn)  AS totalIn,
                       SUM(bytesOut) AS totalOut
                FROM trafficEvent
                WHERE timestamp >= ? AND timestamp <= ? AND processKey = ?
                GROUP BY bucket
                ORDER BY bucket
            """, arguments: [bucketSeconds, bucketSeconds, since, until, processKey])

            return rows.map { row in
                TimelinePoint(
                    timestamp: row["bucket"],
                    bytesIn: row["totalIn"],
                    bytesOut: row["totalOut"]
                )
            }
        }
    }

    /// 获取数据库中的数据时间范围
    func timeRange() throws -> (first: TimeInterval, last: TimeInterval) {
        guard let writer = dbWriter else { return (0, 0) }

        return try writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(timestamp) as first, MAX(timestamp) as last
                FROM trafficEvent
            """)
            return (
                first: row?["first"] ?? 0,
                last: row?["last"] ?? 0
            )
        }
    }

    /// 删除指定时间之前的数据
    func deleteBefore(_ timestamp: TimeInterval) throws {
        guard let writer = dbWriter else { return }

        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM trafficEvent WHERE timestamp < ?",
                arguments: [timestamp]
            )
        }
    }

    /// 数据库文件大小
    /// 数据库占用的磁盘空间。
    ///
    /// **要把 `-wal` 一起算上。** WAL 模式下新写入先落在 write-ahead log 里，
    /// checkpoint 之后才并入主库文件 —— 只看主库文件会严重少报：
    /// 实测刚写完两万行时主库仍是 4096 字节，数据全在 WAL 中。
    func databaseSize() -> Int64 {
        guard let path = currentDBPath else { return 0 }
        return ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            total += (attributes?[.size] as? Int64) ?? 0
        }
    }

    /// 把 WAL 并回主库，让页统计和文件大小反映真实情况
    func checkpoint() throws {
        guard let writer = dbWriter else { return }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Testing

    /// 重置状态（仅用于测试）
    func resetForTesting() {
        isSetup = false
        dbWriter = nil
        currentDBPath = nil
    }
}

// MARK: - Query Result Types

/// 进程流量汇总
struct ProcessSummary: Identifiable {
    var id: String { processKey }
    let processKey: String
    let bundleId: String?
    let displayName: String
    let totalIn: Int64
    let totalOut: Int64
    let sampleCount: Int
    let firstSeen: TimeInterval
    let lastSeen: TimeInterval

    var totalBytes: Int64 { totalIn + totalOut }
}

/// 时间线数据点
struct TimelinePoint: Identifiable, Equatable {
    var id: TimeInterval { timestamp }
    let timestamp: TimeInterval
    let bytesIn: Int64
    let bytesOut: Int64

    var totalBytes: Int64 { bytesIn + bytesOut }
}
