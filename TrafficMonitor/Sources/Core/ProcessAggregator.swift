import Foundation

/// 进程聚合器
///
/// 将 PID 级别的 delta 聚合到 ProcessIdentifier（Bundle ID 优先）。
///
/// 聚合规则:
///  1. PID → ProcessHelper.bundleIdentifier(for:) → 获取 Bundle ID
///  2. 有 Bundle ID → ProcessIdentifier(bundleId: "com.google.Chrome", execName: "Google Chrome")
///  3. 无 Bundle ID → ProcessIdentifier(bundleId: nil, execName: "mds")
///
/// 这样 Chrome 的几十个子进程（Google Chrome, Google Chrome Helper, ...）
/// 全部聚合到一个条目下。
enum ProcessAggregator {
    /// 将 PID 级别的 delta 按 Bundle ID 聚合
    ///
    /// - Parameter pidDeltas: DeltaCalculator 输出的 PID 级别增量
    /// - Returns: 按 ProcessIdentifier 聚合后的 ProcessDelta 列表
    static func aggregateDeltas(_ pidDeltas: [PIDDelta]) -> [ProcessDelta] {
        var grouped: [ProcessIdentifier: (bytesIn: Int64, bytesOut: Int64, interval: TimeInterval, isEstimated: Bool)] = [:]

        for d in pidDeltas {
            let identifier = ProcessIdentifier(
                bundleId: ProcessHelper.bundleIdentifier(for: d.pid),
                execName: d.execName
            )

            if let existing = grouped[identifier] {
                grouped[identifier] = (
                    bytesIn: existing.bytesIn + d.bytesIn,
                    bytesOut: existing.bytesOut + d.bytesOut,
                    interval: d.interval,
                    isEstimated: existing.isEstimated && d.isEstimated
                )
            } else {
                grouped[identifier] = (
                    bytesIn: d.bytesIn,
                    bytesOut: d.bytesOut,
                    interval: d.interval,
                    isEstimated: d.isEstimated
                )
            }
        }

        return grouped.map { ident, vals in
            ProcessDelta(
                identifier: ident,
                bytesIn: vals.bytesIn,
                bytesOut: vals.bytesOut,
                interval: vals.interval,
                isEstimated: vals.isEstimated
            )
        }
    }
}
