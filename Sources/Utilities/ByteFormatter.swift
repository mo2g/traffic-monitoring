import Foundation

/// 字节格式化工具
enum ByteFormatter {
    /// 格式化为人类可读的字符串
    /// - Parameter bytes: 字节数
    /// - Returns: 如 "1.2 MB", "500 KB", "0 B"
    static func string(bytes: Int64) -> String {
        let absBytes = abs(bytes)
        if absBytes < 1024 {
            return "\(bytes) B"
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(absBytes) / 1024.0
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let sign = bytes < 0 ? "-" : ""
        return String(format: "%@%.1f %@", sign, value, units[unitIndex])
    }

    /// 格式化为紧凑形式（用于表格等）
    static func stringCompact(bytes: Int64) -> String {
        string(bytes: bytes)
            .replacingOccurrences(of: " ", with: "")
    }

    /// 菜单栏用的紧凑速率，**恒定 5 个字符**（如 " 1.2M"、" 999K"、"    0"）
    ///
    /// 定长是硬要求：菜单栏标签每秒刷新，宽度一变 NSStatusItem 就要重新测量，
    /// 既会让整条菜单栏抖动，也会触发 AppKit 的布局递归警告。
    static func rateStringCompact(bytesPerSecond: Double) -> String {
        let units = ["", "K", "M", "G", "T"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = index == 0
            ? String(format: "%.0f", value)
            : String(format: value >= 10 ? "%.0f" : "%.1f", value) + units[index]
        return String(repeating: " ", count: max(0, 5 - text.count)) + text
    }

    /// 格式化为速率形式（如 "1.2 MB/s"）
    static func rateString(bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
        let units = ["KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond / 1024.0
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
