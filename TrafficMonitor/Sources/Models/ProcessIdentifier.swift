import AppKit
import Foundation

/// 进程标识符（用于聚合的键）
///
/// 优先使用 Bundle ID 来标识应用，将 Chrome 的几十个子进程归为一个组。
/// 对于没有 Bundle ID 的守护进程/CLI 工具，fallback 到执行文件名。
struct ProcessIdentifier: Hashable, Codable, CustomStringConvertible {
    /// Bundle ID（如 "com.google.Chrome"），可能为 nil（非 .app 进程）
    let bundleId: String?

    /// 进程执行文件名（fallback，当无 Bundle ID 时使用）
    let execName: String

    var description: String {
        bundleId ?? execName
    }

    /// 显示名
    /// 优先使用应用的本地化名称，其次从 Bundle ID 提取，最后用 execName
    var displayName: String {
        if let bid = bundleId {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bid)
                .first,
                let name = app.localizedName {
                return name
            }
            return bid.components(separatedBy: ".").last ?? bid
        }
        return execName
    }

    /// 排序键
    var sortKey: String {
        displayName.lowercased()
    }
}
