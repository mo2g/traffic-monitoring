import XCTest
@testable import TrafficMonitor

final class NettopDaemonTests: XCTestCase {
    func testInstantiation() {
        let daemon = NettopDaemon()
        XCTAssertNotNil(daemon)
    }

    func testStartStop() async throws {
        let daemon = NettopDaemon()
        let stream = await daemon.start(minInterval: 2.0)
        // 读第一张快照, 最多等 8 秒就超时
        let deadline = Date().addingTimeInterval(8)
        var count = 0
        for await _ in stream {
            count += 1
            if count >= 1 || Date() > deadline { break }
        }
        await daemon.stop()
        XCTAssertGreaterThanOrEqual(count, 1)
    }
}
