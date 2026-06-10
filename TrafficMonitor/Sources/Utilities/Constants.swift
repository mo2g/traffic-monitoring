import Foundation

/// 全局常量
enum Constants {
    /// 默认采集间隔（秒）
    static let defaultInterval: TimeInterval = 5.0

    /// 最小允许的采集间隔
    static let minInterval: TimeInterval = 2.0

    /// nettop 路径（自动检测）
    static var nettopPath: String {
        // macOS 15+ 使用 /usr/bin/nettop，旧版本在 /usr/sbin/
        let candidates = [
            "/usr/sbin/nettop",   // macOS 14-
            "/usr/bin/nettop",    // macOS 15+
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/sbin/nettop" // 默认
    }

    /// 子进程脚本名（Bundle 内路径）
    static let collectorScriptName = "collector.sh"

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

    /// 快照输出结束分隔符
    static let snapshotEndMarker = "---SNAPSHOT_END---"

    /// 错误分隔符
    static let errorMarkerPrefix = "---ERROR:"

    /// 心跳响应
    static let pongMarker = "---PONG---"

    /// 子进程输出读取超时（秒）
    static let snapshotTimeout: TimeInterval = 10.0

    /// 子进程崩溃后自动重连最大次数
    static let maxReconnectAttempts = 3

    /// 排除的进程名（始终不显示）
    static let alwaysExcludedProcesses: Set<String> = [
        "kernel_task", "launchd", "WindowServer",
    ]
}
