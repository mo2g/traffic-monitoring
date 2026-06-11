import Foundation

// MARK: - 采集状态

enum CollectorStatus: Equatable {
    case idle
    case running
    case stopped
    case error(String)
}

// MARK: - NettopProcess

/// 直接运行 nettop（macOS 14+ 无需 root）
///
/// 每个 tick 调用 `takeSnapshot()`:
///   1. Process() 执行 `nettop -l 1 -n -P -J bytes_in,bytes_out,state` (TCP)
///   2. Process() 执行 `nettop -m udp -l 1 -n -P -J bytes_in,bytes_out,state` (UDP)
///   3. 拼接输出, 用 ---SNAPSHOT_SEPARATOR--- 分隔, 保持与前版兼容
actor NettopProcess {
    private let nettopPath: String

    init() {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") {
            nettopPath = "/usr/bin/nettop"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/sbin/nettop") {
            nettopPath = "/usr/sbin/nettop"
        } else {
            nettopPath = "/usr/sbin/nettop"
        }
    }

    /// 返回 nettop 的 TCP+UDP 文本输出, 或 nil 如果 nettop 不可用
    /// TCP 和 UDP 并行执行以降低单次 tick 延迟
    func takeSnapshot() async -> String? {
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .userInitiated)
            let tcpBox = Box()
            let udpBox = Box()

            queue.async(group: group) {
                tcpBox.value = self.runNettop(args: ["-l", "1", "-n", "-P", "-J", "bytes_in,bytes_out,state"])
            }
            queue.async(group: group) {
                udpBox.value = self.runNettop(args: ["-m", "udp", "-l", "1", "-n", "-P", "-J", "bytes_in,bytes_out,state"])
            }

            group.notify(queue: queue) {
                guard let tcp = tcpBox.value else {
                    continuation.resume(returning: nil); return
                }
                if let udp = udpBox.value, !udp.isEmpty {
                    continuation.resume(returning: tcp + "\n---SNAPSHOT_SEPARATOR---\n" + udp)
                } else {
                    continuation.resume(returning: tcp)
                }
            }
        }
    }

    /// 线程安全的值容器
    private final class Box { var value: String? }

    private nonisolated func runNettop(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nettopPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
