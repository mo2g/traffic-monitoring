import Foundation

// MARK: - 采集状态

enum CollectorStatus: Equatable {
    case idle
    case authorizing
    case running
    case stopped
    case error(String)
}

// MARK: - RootCollector

/// 持久 root 子进程（无 sudo，纯 AppleScript 启动）
///
/// ```
/// 首次启动:
///   NSAppleScript 弹窗（仅一次！）
///   → do shell script "nohup collector.sh &" with administrator privileges
///   → collector.sh 以 root 启动，循环检测 trigger 文件
///
/// 采集循环:
///   takeSnapshot():
///     1. 记下 output 的当前 mtime
///     2. touch trigger → collector.sh 检测到 → 删除 trigger → 执行 nettop → 写入 output
///     3. 轮询 output mtime 变化 → 读取并解析
///
/// 关闭:
///   AppleScript: do shell script "pkill -f collector.sh" with administrator privileges
/// ```
actor RootCollector {
    private(set) var status: CollectorStatus = .idle
    private var errorCount = 0

    private let triggerPath = "/tmp/tm_nettop_trigger"
    private let outputPath  = "/tmp/tm_nettop_output"
    private let scriptPath   = "/tmp/tm_collector.sh"

    // 上次读取的 output 文件 mtime（用于检测更新）
    private var lastOutputMtime: TimeInterval = 0

    // 脚本内容（启动时写入 /tmp）
    private var scriptContent: String {
        let body = """
        #!/bin/bash
        TRIGGER="\(triggerPath)"
        OUTPUT="\(outputPath)"

        # auto-detect nettop
        if [ -x "/usr/bin/nettop" ]; then N="/usr/bin/nettop"
        elif [ -x "/usr/sbin/nettop" ]; then N="/usr/sbin/nettop"
        else exit 1; fi

        echo "collector: root daemon started (pid $$, nettop=$N)" >&2

        while true; do
            if [ -f "$TRIGGER" ]; then
                rm -f "$TRIGGER"
                $N -l 1 -n -P -J bytes_in,bytes_out,state > "$OUTPUT" 2>/dev/null
                echo "---SNAPSHOT_END---" >> "$OUTPUT"
            fi
            sleep 0.5
        done
        """
        return body
    }

    // MARK: - Public

    func authorizeAndStart() async -> Bool {
        guard status == .idle || status == .stopped else {
            return status == .running
        }

        status = .authorizing

        // Step 1: 写入 collector.sh 到 /tmp
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            status = .error("无法写入 collector.sh")
            return false
        }

        // Step 2: 清理旧 trigger/output
        try? FileManager.default.removeItem(atPath: triggerPath)
        try? FileManager.default.removeItem(atPath: outputPath)

        // Step 3: AppleScript 弹窗一次 + 后台启动 collector.sh（绕过 sudo！）
        let ok = await launchCollectorViaAppleScript()
        guard ok else {
            status = .error("授权已取消")
            return false
        }

        // Step 4: 等子进程就绪（做一次测试采集验证）
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        let testOutput = await takeSnapshotInternal()
        if testOutput == nil {
            status = .error("采集子进程未就绪")
            return false
        }

        status = .running
        errorCount = 0
        return true
    }

    func takeSnapshot() async -> String? {
        guard status == .running else { return nil }

        let output = await takeSnapshotInternal()
        if output == nil {
            errorCount += 1
            if errorCount >= Constants.maxReconnectAttempts {
                status = .error("采集失败 \(errorCount) 次")
            }
            return nil
        }

        errorCount = 0
        return output
    }

    func shutdown() {
        guard status == .running else { return }
        // 通过 AppleScript 杀掉子进程
        _ = executeMainThread(script: """
        do shell script "pkill -f tm_collector.sh" with administrator privileges
        """)
        status = .stopped
    }

    // MARK: - Private: AppleScript

    /// 弹窗授权 + 后台启动 collector.sh（仅一次，无 sudo）
    private func launchCollectorViaAppleScript() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let script = NSAppleScript(source: """
                do shell script "chmod +x \(self.scriptPath) && nohup \(self.scriptPath) > /dev/null 2>&1 & echo ok" with administrator privileges
                """)

                var error: NSDictionary?
                _ = script?.executeAndReturnError(&error)

                if let err = error {
                    let code = err[NSAppleScript.errorNumber] as? Int ?? -1
                    print("[RootCollector] 授权失败 (\(code)): \(err[NSAppleScript.errorMessage] ?? "")")
                    continuation.resume(returning: false)
                } else {
                    print("[RootCollector] 授权成功，子进程已后台启动")
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private func executeMainThread(script source: String) -> String? {
        var output: String?
        DispatchQueue.main.sync {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            output = result?.stringValue
        }
        return output
    }

    // MARK: - Private: 采集

    private func takeSnapshotInternal() async -> String? {
        // 1. 记录当前 output mtime
        var currentMtime: TimeInterval = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath) {
            currentMtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }

        // 2. 创建 trigger 文件通知子进程
        FileManager.default.createFile(atPath: triggerPath, contents: nil)

        // 3. 轮询等待 output 更新（最长 10s）
        let deadline = Date().addingTimeInterval(Constants.snapshotTimeout)

        while Date() < deadline {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  mtime > currentMtime else {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue
            }

            // output 已更新
            lastOutputMtime = mtime

            // 读取
            guard let content = try? String(contentsOfFile: outputPath, encoding: .utf8) else {
                return nil
            }

            // 按分隔符提取 nettop 部分
            if let range = content.range(of: "---SNAPSHOT_END---") {
                return String(content[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }

            return content.trimmingCharacters(in: .whitespaces)
        }

        return nil // timeout
    }
}
