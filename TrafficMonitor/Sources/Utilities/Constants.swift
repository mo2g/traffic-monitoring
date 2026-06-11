import Foundation

/// 全局常量
enum Constants {
    /// 默认采集间隔（秒）— 2s 是 CPU 与实时性的平衡点
    /// 1s 可用但 CPU 较高（nettop 每次 150-300ms），推荐 2s+
    static let defaultInterval: TimeInterval = 2.0

    /// 最小允许的采集间隔
    static let minInterval: TimeInterval = 1.0

    /// 批量保存到数据库的默认间隔（秒）
    static let batchSaveInterval: TimeInterval = 5.0

    /// 数据库文件名
    static let databaseFileName = "traffic_monitor.db"

    /// 数据库目录（Application Support 下）
    static var databaseDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("TrafficMonitor")
    }

    /// 数据库完整路径
    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent(databaseFileName)
    }

    /// 快照内部 TCP/UDP 分隔符
    static let snapshotSeparatorMarker = "---SNAPSHOT_SEPARATOR---"

    /// 排除的进程名（始终不显示）
    static let alwaysExcludedProcesses: Set<String> = [
        "kernel_task", "launchd", "WindowServer",
    ]
}
