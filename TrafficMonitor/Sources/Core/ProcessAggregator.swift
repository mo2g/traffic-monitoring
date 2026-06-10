import Foundation

/// 进程聚合器
///
/// 将 nettop 的原始 ProcessRecord（每个 PID 一条）聚合到 ProcessIdentifier（Bundle ID 优先）。
///
/// 聚合规则:
///  1. PID → ProcessHelper.bundleIdentifier(for:) → 获取 Bundle ID
///  2. 有 Bundle ID → ProcessIdentifier(bundleId: "com.google.Chrome", execName: "Google Chrome")
///  3. 无 Bundle ID → ProcessIdentifier(bundleId: nil, execName: "mds")
///
/// 这样 Chrome 的几十个子进程（Google Chrome, Google Chrome Helper, ...）
/// 全部聚合到一个条目下。
enum ProcessAggregator {
    /// 聚合原始进程记录
    ///
    /// - Parameter records: nettop 解析出的原始记录
    /// - Returns: 更新后的快照（records 字段已按 identifier 聚合）
    static func aggregate(
        records: [ProcessRecord],
        timestamp: Date = Date()
    ) -> ProcessSnapshot {
        var grouped: [ProcessIdentifier: (bytesIn: Int64, bytesOut: Int64)] = [:]

        for record in records {
            let identifier = record.identifier

            if let existing = grouped[identifier] {
                grouped[identifier] = (
                    bytesIn: existing.bytesIn + record.bytesIn,
                    bytesOut: existing.bytesOut + record.bytesOut
                )
            } else {
                grouped[identifier] = (
                    bytesIn: record.bytesIn,
                    bytesOut: record.bytesOut
                )
            }
        }

        return ProcessSnapshot(
            timestamp: timestamp,
            records: grouped,
            rawRecords: records
        )
    }
}
