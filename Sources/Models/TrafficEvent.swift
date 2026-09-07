import Foundation

/// SQLite 中的单条流量事件
///
/// 每次采集快照的差值（按进程聚合后）产生一条或多条 TrafficEvent。
struct TrafficEvent: Identifiable, Codable {
    /// 自增主键
    var id: Int64?

    /// 快照时间戳（Unix 秒）
    let timestamp: TimeInterval

    /// 采集间隔（两次快照之间的秒数）
    let interval: TimeInterval

    /// 聚合后的进程标识字符串（bundleId 或 execName）
    let processKey: String

    /// Bundle ID（可能为空）
    let bundleId: String?

    /// 显示名
    let displayName: String

    /// 本次间隔内的增量接收字节
    let bytesIn: Int64

    /// 本次间隔内的增量发送字节
    let bytesOut: Int64

    /// 速率（bytesIn / interval）
    var rxRate: Double {
        Double(bytesIn) / max(interval, 0.1)
    }

    /// 发送速率
    var txRate: Double {
        Double(bytesOut) / max(interval, 0.1)
    }

    /// 总流量
    var totalBytes: Int64 {
        bytesIn + bytesOut
    }

    /// 总速率
    var totalRate: Double {
        rxRate + txRate
    }
}

// MARK: - GRDB 适配

import GRDB

extension TrafficEvent: TableRecord, FetchableRecord, MutablePersistableRecord {
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let interval = Column(CodingKeys.interval)
        static let processKey = Column(CodingKeys.processKey)
        static let bundleId = Column(CodingKeys.bundleId)
        static let displayName = Column(CodingKeys.displayName)
        static let bytesIn = Column(CodingKeys.bytesIn)
        static let bytesOut = Column(CodingKeys.bytesOut)
    }
}
