import AppKit
import SwiftUI

/// 进程图标缓存（主线程侧）
///
/// 采集管线只传路径（`String`），真正的 `NSImage` 在这里按需加载 ——
/// AppKit 图像不是 `Sendable`，不该穿过 actor 边界。
///
/// 每个 key 只查一次系统，未命中也缓存（否则每次重绘都会重试一遍失败的路径）。
/// `NSWorkspace.icon(forFile:)` 对 `.app` 包和裸可执行文件都返回图标，
/// 后者拿到的是系统通用可执行文件图标 —— 与活动监视器的表现一致。
@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()

    private var cache: [String: NSImage?] = [:]

    private init() {}

    /// - Parameters:
    ///   - path: 采集时解析出的 `.app` 包或可执行文件路径
    ///   - bundleId: 路径缺失时的退路（历史数据只有 bundleId，没有路径）
    func icon(path: String?, bundleId: String?) -> NSImage? {
        guard let key = path ?? bundleId else { return nil }
        if let cached = cache[key] { return cached }

        let image = Self.load(path: path, bundleId: bundleId)
        cache[key] = image
        return image
    }

    func removeAll() { cache.removeAll() }

    private static func load(path: String?, bundleId: String?) -> NSImage? {
        if let path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        // 历史行：只有 bundleId，问 LaunchServices 要安装路径。
        // 每个标识最多走一次，之后命中缓存。
        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

// MARK: - 视图

/// 优先显示真实应用图标，拿不到时回退到 SF Symbol
struct ProcessIcon: View {
    let iconPath: String?
    let bundleId: String?
    let fallbackSymbol: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = ProcessIconCache.shared.icon(path: iconPath, bundleId: bundleId) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.accentColor)
            }
        }
        .frame(width: size, height: size)
    }
}

extension ProcessIcon {
    init(row: ProcessRow, size: CGFloat = 16) {
        self.init(iconPath: row.iconPath, bundleId: row.bundleId,
                  fallbackSymbol: row.icon, size: size)
    }
}
