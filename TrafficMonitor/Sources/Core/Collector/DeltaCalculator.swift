import Foundation

/// 快照差值计算器
///
/// nettop 返回的是进程自启动以来的累计字节数，需要计算相邻快照的差值
/// 才能得到某个时间段内的实际流量增量。
///
/// ```
/// 快照时序:
///   t0: Snap0 { Chrome: 100MB, Edge: 50MB  }
///   t1: Snap1 { Chrome: 150MB, Edge: 80MB  }  → Δ = Snap1 - Snap0
///   t2: Snap2 { Chrome: 180MB, Edge: 100MB }  → Δ = Snap2 - Snap1
/// ```
///
/// 进程重启处理:
///   如果同名（同 Bundle ID）进程的累计字节比上次小，说明进程重启了
///   → 使用当前值作为增量（而不是负值）
enum DeltaCalculator {
    /// 计算两个快照之间的流量差值
    ///
    /// - Parameters:
    ///   - prev: 上一个快照（nil 表示首次采集，仅记录基线不产生增量）
    ///   - curr: 当前快照
    ///   - interval: 两次快照之间的时间间隔（秒）
    /// - Returns: 按 ProcessIdentifier 聚合的流量增量列表
    static func compute(
        from prev: ProcessSnapshot?,
        to curr: ProcessSnapshot,
        interval: TimeInterval
    ) -> [ProcessDelta] {
        guard let prev = prev else {
            // 首次快照，没有基准，不产生增量
            return []
        }

        var deltas: [ProcessDelta] = []

        // 当前快照中的所有进程
        for (identifier, currStats) in curr.records {
            let prevStats = prev.records[identifier]

            var deltaIn: Int64
            var deltaOut: Int64

            if let prev = prevStats {
                // 正常情况：计算差值
                deltaIn = currStats.bytesIn - prev.bytesIn
                deltaOut = currStats.bytesOut - prev.bytesOut
            } else {
                // 新出现的进程（上次快照中没有）
                // 使用当前值的 10% 作为保守估计（避免将历史累计全部算入）
                let conservativeRatio: Int64 = 10 // ratio = current/10
                deltaIn = max(currStats.bytesIn / conservativeRatio, 0)
                deltaOut = max(currStats.bytesOut / conservativeRatio, 0)
            }

            // 处理计数器回退（进程重启）
            if deltaIn < 0 { deltaIn = max(currStats.bytesIn / 10, 0) }
            if deltaOut < 0 { deltaOut = max(currStats.bytesOut / 10, 0) }

            // 忽略无变化
            guard deltaIn > 0 || deltaOut > 0 else { continue }

            // 过滤异常值（单次增量不应超过合理的网络带宽 * 时间）
            let maxReasonable = Int64(100_000_000) * Int64(interval) // 100 MB/s * interval
            if deltaIn > maxReasonable || deltaOut > maxReasonable {
                // 可能是进程重启导致的异常，使用保守估计
                let cappedIn = min(deltaIn, maxReasonable)
                let cappedOut = min(deltaOut, maxReasonable)
                deltas.append(ProcessDelta(
                    identifier: identifier,
                    bytesIn: cappedIn,
                    bytesOut: cappedOut,
                    interval: interval,
                    isEstimated: false
                ))
            } else {
                deltas.append(ProcessDelta(
                    identifier: identifier,
                    bytesIn: deltaIn,
                    bytesOut: deltaOut,
                    interval: interval,
                    isEstimated: false
                ))
            }
        }

        return deltas
    }
}

/// 单个进程的流量增量
struct ProcessDelta {
    /// 进程标识符
    let identifier: ProcessIdentifier

    /// 时间间隔内的接收字节增量
    let bytesIn: Int64

    /// 时间间隔内的发送字节增量
    let bytesOut: Int64

    /// 采集间隔（秒）
    let interval: TimeInterval

    /// 是否估算值（进程重启导致的实际值不确定时）
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
