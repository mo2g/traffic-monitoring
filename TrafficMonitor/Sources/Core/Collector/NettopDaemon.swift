import Foundation

// MARK: - 采集状态

enum CollectorStatus: Equatable {
    case idle
    case running
    case stopped
    case error(String)
}

// MARK: - NettopDaemon

/// 持久 nettop 守护进程 + AsyncStream 队列
///
/// 使用 `FileHandle.readabilityHandler`（事件驱动）读取 nettop stdout，
/// 逐行解析并以 header 行作为快照边界。
///
/// ```
/// nettop -l 0 → Pipe → readabilityHandler → 行级解析 → header 标记快照边界 → 节流 yield
/// 消费: for await (text, ts) in stream { ... }
/// ```
///
/// ## 为什么用 readabilityHandler 而不是 Timer 轮询
///
/// 1. **事件驱动**：pipe 有数据才触发回调，不浪费 CPU
/// 2. **行级边界**：逐行解析，以 header 行（`bytes_in  bytes_out`）作为快照分隔符，
///    不会因读取时机产生不完整快照
/// 3. **自然跟随节奏**：nettop 每 ~1s 刷新一次，handler 同步触发
/// 4. **无需 buffer trim / 安全截断**：行 buffer 只保留未完成的行
///
/// ## 节流
///
/// header 到达时标记快照边界，但只按 `minYieldInterval` 控制 yield 频率。
/// 中间跳过的快照被静默丢弃（保留最新即可）。
actor NettopDaemon {
    private let nettopPath: String
    private var process: Process?
    private var pipeOutput: Pipe?
    private var continuation: AsyncStream<(String, Date)>.Continuation?
    private var minYieldInterval: TimeInterval = 2.0
    private var lastYieldTime = Date.distantPast
    private let headerMarker = "bytes_in       bytes_out"

    // 行级解析状态
    private var pendingText = ""          // 未完成的行（跨 handler 回调）
    private var currentLines: [String] = [] // 当前快照已收集的进程行
    private let maxPendingSize = 500_000  // pendingText 安全上限

    init() {
        let candidates = ["/usr/bin/nettop", "/usr/sbin/nettop"]
        nettopPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/nettop"
    }

    func start(minInterval: TimeInterval) -> AsyncStream<(String, Date)> {
        self.minYieldInterval = minInterval
        return AsyncStream { cont in
            self.continuation = cont
            launchProcess()
        }
    }

    func stop() {
        // 必须先清除 handler 再 terminate，否则 terminate 可能导致
        // handler 以 EOF 触发，与正常清理流程竞争
        pipeOutput?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        continuation?.finish()
    }

    // MARK: - Process

    private func launchProcess() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nettopPath)
        p.arguments = ["-l", "0", "-P", "-n", "-J", "bytes_in,bytes_out,state"]
        let pPipe = Pipe()
        p.standardOutput = pPipe
        p.standardError = FileHandle.nullDevice

        pPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF：nettop 进程已退出，pipe 关闭
                handle.readabilityHandler = nil
                let daemon = self
                Task { await daemon?.handleEOF() }
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let daemon = self
            // Actor 确保 processIncoming 调用串行化
            Task { await daemon?.processIncoming(text) }
        }

        do { try p.run() } catch {
            // 启动失败，通知 consumer
            Task { [continuation] in continuation?.finish() }
            return
        }
        process = p
        pipeOutput = pPipe
    }

    // MARK: - Line Parsing

    /// 将新到达的文本追加到 line buffer，提取完整行并逐行处理
    private func processIncoming(_ text: String) {
        pendingText += text

        // 安全上限：防止 nettop 输出不带换行符导致内存无限增长
        if pendingText.utf8.count > maxPendingSize {
            let keep = maxPendingSize / 2
            // 跳到下一个换行符，避免从行中间截断
            if let idx = pendingText.utf8.index(
                pendingText.utf8.endIndex, offsetBy: -keep,
                limitedBy: pendingText.utf8.startIndex
            ), let nl = pendingText[idx...].firstIndex(of: "\n") {
                pendingText = String(pendingText[nl...].dropFirst())
            } else if let idx = pendingText.utf8.index(
                pendingText.utf8.endIndex, offsetBy: -keep,
                limitedBy: pendingText.utf8.startIndex
            ) {
                pendingText = String(pendingText[idx...])
            }
        }

        // 提取所有完整行
        while let nl = pendingText.firstIndex(of: "\n") {
            let line = String(pendingText[..<nl])
            pendingText = String(pendingText[pendingText.index(after: nl)...])
            processLine(line)
        }
    }

    /// 处理一行文本
    private func processLine(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }

        if t.contains(headerMarker) {
            // ── 快照边界 ──
            // 上一个 header 以来累积的进程行 = 一个完整快照
            if !currentLines.isEmpty {
                emitSnapshot()
            }
            currentLines = []
        } else if t.hasPrefix("nettop") && currentLines.isEmpty {
            // 首个 header 之前跳过 "nettop -l 0 -P -n, polling ..." 引导行
            return
        } else {
            // 进程数据行
            currentLines.append(line)
        }
    }

    // MARK: - Snapshot Emission

    /// 将 currentLines 组装为完整快照文本，按节流控制 yield
    private func emitSnapshot() {
        // 还原完整格式（与 nettop -l 1 单次输出格式一致，parser 依赖 header）
        let snap = headerMarker + "\n" + currentLines.joined(separator: "\n")
        let now = Date()

        if now.timeIntervalSince(lastYieldTime) >= minYieldInterval {
            lastYieldTime = now
            continuation?.yield((snap, now))
        }
        // 如果节流跳过，该快照被丢弃 —— consumer 只需要最新数据
    }

    // MARK: - EOF Handling

    private func handleEOF() {
        // nettop 退出前可能有最后一张未发出的快照
        if !currentLines.isEmpty {
            emitSnapshot()
        }
        // stream 自然结束，consumer 的 for-await 循环退出
    }
}
