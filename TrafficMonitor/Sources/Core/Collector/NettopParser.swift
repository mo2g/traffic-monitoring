import Foundation

/// nettop 文本输出解析器
///
/// 解析 `nettop -l 1 -n -P -J bytes_in,bytes_out,state` 的输出。
///
/// 输出格式示例:
/// ```
/// nettop -l1 -P -n, polling every 1.0 seconds
///                                                      bytes_in    bytes_out    state
/// Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
/// Google Chrome Helper.1235    tcp4 10.0.0.1:80          100KiB     50.0KiB  Established
/// com.apple.WebKit.5678        tcp4 *:*                   0B         0B       Listen
/// ```
enum NettopParser {
    /// 解析 nettop 的文本输出，返回进程记录列表
    /// - Parameter raw: nettop 的 stdout 原始文本
    /// - Returns: 解析出的进程记录（仅包含有流量的进程）
    static func parse(_ raw: String) -> [ProcessRecord] {
        let lines = raw.components(separatedBy: "\n")
        var records: [ProcessRecord] = []
        // 按 PID 去重（同一个进程可能有多条连接记录，取 sum）
        var seen: [Int32: (name: String, inBytes: Int64, outBytes: Int64)] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // 跳过表头
            if trimmed.contains("nettop") || trimmed.contains("bytes_in") {
                continue
            }

            // 跳过汇总/统计行
            if trimmed.hasPrefix("-----") || trimmed.hasPrefix("=") {
                continue
            }

            // 找 "进程名.PID" token——可能在 parts[0]，也可能在后续
            // （因为进程名含空格，如 "Google Chrome.1234" → split 为 ["Google", "Chrome.1234"]）
            let parts = lineComponents(trimmed)
            guard parts.count >= 3 else { continue }

            // 找到匹配 "name.PID" 格式的 token
            let pidPattern = try? NSRegularExpression(pattern: #"\.\d{1,6}$"#)
            var procIndex: Int?
            var procToken: String?
            for (i, part) in parts.enumerated() {
                let range = NSRange(part.startIndex..., in: part)
                if pidPattern?.firstMatch(in: part, range: range) != nil {
                    procIndex = i
                    procToken = part
                    break
                }
            }
            guard let idx = procIndex, let token = procToken,
                  let dotIndex = token.lastIndex(of: ".") else { continue }

            let pidStr = String(token[token.index(after: dotIndex)...])
            guard let pid = Int32(pidStr) else { continue }

            // 进程名：PID token 之前的所有 part + PID token 中 "." 之前的部分
            var nameParts = Array(parts[0..<idx])
            nameParts.append(String(token[..<dotIndex]))
            let procName = nameParts.joined(separator: " ")

            // 在 PID token 之后的 part 中找字节值
            let tailParts = Array(parts[(idx + 1)...])
            let bytePattern = try! NSRegularExpression(
                pattern: #"^[\d.]+[KMGT]?i?B$"#
            )
            var byteValues: [String] = []
            for part in tailParts.suffix(4) {
                let range = NSRange(part.startIndex..., in: part)
                if bytePattern.firstMatch(in: part, range: range) != nil {
                    byteValues.append(part)
                }
            }

            guard byteValues.count >= 2 else { continue }

            let bytesIn = parseBytes(byteValues[byteValues.count - 2])
            let bytesOut = parseBytes(byteValues[byteValues.count - 1])

            // 按 PID 聚合（同一进程的多条连接）
            if let existing = seen[pid] {
                seen[pid] = (name: procName,
                             inBytes: existing.inBytes + bytesIn,
                             outBytes: existing.outBytes + bytesOut)
            } else {
                seen[pid] = (name: procName, inBytes: bytesIn, outBytes: bytesOut)
            }
        }

        // 过滤掉零流量 + 系统进程
        for (pid, record) in seen {
            guard record.inBytes > 0 || record.outBytes > 0 else { continue }
            guard !Constants.alwaysExcludedProcesses.contains(record.name) else { continue }

            records.append(ProcessRecord(
                pid: pid,
                execName: record.name,
                bytesIn: record.inBytes,
                bytesOut: record.outBytes
            ))
        }

        return records
    }

    // MARK: - Private

    /// 将一行按空白分割为数组（保留空元素之间的空白意义）
    private static func lineComponents(_ line: String) -> [String] {
        line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// 解析 nettop 的字节值（如 "1.0MiB" → 1048576）
    private static func parseBytes(_ raw: String) -> Int64 {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")

        if cleaned == "0B" || cleaned == "0" { return 0 }

        let units: [(String, Int64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("TB",  1_000_000_000_000),
            ("GB",  1_000_000_000),
            ("MB",  1_000_000),
            ("KB",  1_000),
            ("B",   1),
        ]

        for (suffix, multiplier) in units {
            if cleaned.hasSuffix(suffix) {
                let numStr = String(cleaned.dropLast(suffix.count))
                if let num = Double(numStr) {
                    return Int64(num * Double(multiplier))
                }
            }
        }

        return Int64(cleaned) ?? 0
    }
}
