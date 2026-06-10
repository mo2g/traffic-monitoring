import AppKit
import Foundation

/// 进程信息辅助工具
enum ProcessHelper {
    /// PID → Bundle ID 缓存
    private static var pidToBundleCache: [Int32: String] = [:]
    private static var lastCacheRefresh = Date.distantPast
    private static let cacheTTL: TimeInterval = 30 // 30 秒刷新一次

    /// 获取 PID 对应的 Bundle ID
    ///
    /// 优先级:
    /// 1. NSRunningApplication → bundleIdentifier (最可靠)
    /// 2. proc_pidpath → 从路径解析 .app Bundle
    /// 3. fallback: nil (使用进程名)
    static func bundleIdentifier(for pid: Int32) -> String? {
        // 使用缓存（30 秒有效期）
        let now = Date()
        if now.timeIntervalSince(lastCacheRefresh) > cacheTTL {
            refreshCache()
            lastCacheRefresh = now
        }
        if let cached = pidToBundleCache[pid] {
            return cached
        }

        // 缓存未命中，尝试实时查找
        return lookupBundleIdentifier(for: pid)
    }

    /// 获取 PID 对应的显示名称
    /// 优先使用 Bundle 的显示名，其次用进程名
    static func displayName(for pid: Int32) -> String {
        if let bundleId = bundleIdentifier(for: pid),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
           let name = app.localizedName {
            return name
        }
        return procName(for: pid)
    }

    // MARK: - Private

    private static func refreshCache() {
        pidToBundleCache.removeAll()
        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier {
                pidToBundleCache[app.processIdentifier] = bundleId
            }
        }
    }

    private static func lookupBundleIdentifier(for pid: Int32) -> String? {
        // 方法1: NSRunningApplication
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier {
            return bundleId
        }

        // 方法2: 通过可执行文件路径反查 .app Bundle
        let exePath = procPath(for: pid)
        if exePath.contains(".app/") {
            let components = exePath.components(separatedBy: "/")
            if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                let bundlePath = "/" + components[0...appIndex].joined(separator: "/")
                return Bundle(path: bundlePath)?.bundleIdentifier
            }
        }

        return nil
    }

    /// 获取进程名（调 libproc）
    static func procName(for pid: Int32) -> String {
        var name = [CChar](repeating: 0, count: 256)
        let ret = proc_name(pid, &name, 256)
        if ret > 0 {
            return String(cString: name)
        }
        return "unknown"
    }

    // MARK: - libproc C 函数声明

    @_silgen_name("proc_name")
    private static func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

    @_silgen_name("proc_pidpath")
    private static func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

    private static func procPath(for pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        let ret = proc_pidpath(pid, &path, 4096)
        if ret > 0 {
            return String(cString: path)
        }
        return "unknown"
    }
}
