import Foundation

/// 快照差值计算器
///
/// nettop 返回的是进程自启动以来的累计字节数，需要计算相邻快照的差值
/// 才能得到某个时间段内的实际流量增量。
///
/// **核心设计：在 PID 级别计算增量，然后再按 Bundle ID 聚合。**
///
/// 为什么必须在 PID 级别计算：
/// - 进程（PID）频繁创建和退出（Chrome 每开/关一个 tab 就是一次生命周期）
/// - 如果在 Bundle ID 聚合之后再算差值，PID 退出会导致聚合累计值回退
/// - 累计值回退触发 /10 保守估算 → 虚高速率尖峰
/// - PID 级别：退出的 PID 直接不贡献 delta，新 PID 的累计值即为其增量
///
/// ```
/// PID 增量流程:
///   Snap1: PID 100: 5GB, PID 101: 3GB
///   Snap2: PID 100: 5.1GB, PID 102: 0.5GB (101 退出, 102 新出现)
///   → PID 100 delta: 0.1GB, PID 102 delta: 0.5GB, PID 101: 无 delta
///   → 按 Bundle ID 聚合后: Chrome = 0.6GB ✓
/// ```
enum DeltaCalculator {
    /// 计算两个快照之间的 PID 级别流量差值
    ///
    /// - Parameters:
    ///   - prev: 上一个快照的原始记录（nil = 首次采集，仅记录基线不产生增量）
    ///   - curr: 当前快照的原始记录
    ///   - interval: 两次快照之间的时间间隔（秒）
    ///   - knownPIDs: 历史上见过的所有 PID 集合（用于区分「真正的新进程」和「上次快照遗漏的老进程」）
    /// - Returns: 按 PID 计算的流量增量列表
    static func compute(
        from prev: [ProcessRecord]?,
        to curr: [ProcessRecord],
        interval: TimeInterval,
        knownPIDs: Set<Int32> = []
    ) -> [PIDDelta] {
        guard let prev = prev else {
            // 首次快照，没有基准，不产生增量
            return []
        }

        // 构建 PID → 上次记录的映射
        var prevMap: [Int32: ProcessRecord] = [:]
        for r in prev {
            prevMap[r.pid] = r
        }

        let safeInterval = max(interval, 0.1)
        let roundedInterval = Int64(max(safeInterval, 1.0).rounded())
        var deltas: [PIDDelta] = []

        for r in curr {
            if let p = prevMap[r.pid] {
                // 已有 PID：正常计算差值
                var deltaIn = r.bytesIn - p.bytesIn
                var deltaOut = r.bytesOut - p.bytesOut

                // 计数器回退（极少见：PID 被复用且新进程累计比旧进程小）
                if deltaIn < 0 { deltaIn = max(r.bytesIn / 10, 0) }
                if deltaOut < 0 { deltaOut = max(r.bytesOut / 10, 0) }

                guard deltaIn > 0 || deltaOut > 0 else { continue }

                deltas.append(PIDDelta(
                    pid: r.pid,
                    execName: r.execName,
                    bytesIn: deltaIn,
                    bytesOut: deltaOut,
                    interval: safeInterval,
                    isEstimated: false
                ))
            } else if knownPIDs.contains(r.pid) {
                // 「回归」PID：历史上见过，但上次快照中没有（可能是 nettop 输出遗漏）
                // 使用保守估算 /3，避免将长生命周期进程的全部累计算作增量
                guard r.bytesIn > 0 || r.bytesOut > 0 else { continue }
                let estIn = max(r.bytesIn / 3, 0)
                let estOut = max(r.bytesOut / 3, 0)
                guard estIn > 0 || estOut > 0 else { continue }

                deltas.append(PIDDelta(
                    pid: r.pid,
                    execName: r.execName,
                    bytesIn: estIn,
                    bytesOut: estOut,
                    interval: safeInterval,
                    isEstimated: true
                ))
            } else {
                // 真正的新 PID：从未见过，累计值小，直接使用（加合理上限）
                guard r.bytesIn > 0 || r.bytesOut > 0 else { continue }

                // 10 MB/s * interval 上限（对新进程足够，同时防止极端异常值）
                let maxNewPID = Int64(10_000_000) * roundedInterval
                let cappedIn = min(r.bytesIn, maxNewPID)
                let cappedOut = min(r.bytesOut, maxNewPID)

                deltas.append(PIDDelta(
                    pid: r.pid,
                    execName: r.execName,
                    bytesIn: cappedIn,
                    bytesOut: cappedOut,
                    interval: safeInterval,
                    isEstimated: true
                ))
            }
        }

        return deltas
    }
}

/// 单个 PID 的流量增量
struct PIDDelta {
    let pid: Int32
    let execName: String
    let bytesIn: Int64
    let bytesOut: Int64
    let interval: TimeInterval
    let isEstimated: Bool
}

/// 单个进程（Bundle ID 聚合后）的流量增量
struct ProcessDelta {
    /// 进程标识符
    let identifier: ProcessIdentifier

    /// 时间间隔内的接收字节增量
    let bytesIn: Int64

    /// 时间间隔内的发送字节增量
    let bytesOut: Int64

    /// 采集间隔（秒）
    let interval: TimeInterval

    /// 是否估算值（新 PID 或计数器回退时）
    let isEstimated: Bool

    /// 总字节数
    var totalBytes: Int64 { bytesIn + bytesOut }

    /// 接收速率 (B/s)
    var rxRate: Double { Double(bytesIn) / max(interval, 0.1) }

    /// 发送速率 (B/s)
    var txRate: Double { Double(bytesOut) / max(interval, 0.1) }

    /// 总速率 (B/s)
    var totalRate: Double { rxRate + txRate }
}
