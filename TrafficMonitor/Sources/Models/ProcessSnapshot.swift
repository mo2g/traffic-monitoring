import Foundation

/// 进程快照中的单条原始记录（未经聚合）
struct ProcessRecord: Hashable {
    let pid: Int32
    let execName: String
    let bytesIn: Int64   // 自进程启动以来的累计接收字节
    let bytesOut: Int64  // 自进程启动以来的累计发送字节

    /// 从 PID 解析出的进程标识符
    var identifier: ProcessIdentifier {
        let bundleId = ProcessHelper.bundleIdentifier(for: pid)
        return ProcessIdentifier(bundleId: bundleId, execName: execName)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: ProcessRecord, rhs: ProcessRecord) -> Bool {
        lhs.pid == rhs.pid
    }
}

/// 一次 nettop 快照（按进程聚合后的结果）
struct ProcessSnapshot {
    /// 快照时间戳
    let timestamp: Date

    /// 按 ProcessIdentifier 聚合后的记录
    /// Key = ProcessIdentifier, Value = 该进程组的总 bytes_in / bytes_out
    let records: [ProcessIdentifier: (bytesIn: Int64, bytesOut: Int64)]

    /// 原始记录（未聚合），用于调试
    let rawRecords: [ProcessRecord]
}
