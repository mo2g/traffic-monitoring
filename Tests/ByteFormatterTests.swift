import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - ByteFormatter 单元测试
// ============================================================

final class ByteFormatterTests: XCTestCase {
    func testZeroBytes() {
        XCTAssertEqual(ByteFormatter.string(bytes: 0), "0 B")
    }

    func testBytes() {
        XCTAssertEqual(ByteFormatter.string(bytes: 500), "500 B")
    }

    func testKilobytes() {
        let s = ByteFormatter.string(bytes: 1536)
        XCTAssertTrue(s.hasSuffix("KB"))
        XCTAssertTrue(s.hasPrefix("1.5"))
    }

    func testMegabytes() {
        let s = ByteFormatter.string(bytes: 2_500_000)
        XCTAssertTrue(s.contains("MB"))
    }

    func testGigabytes() {
        let s = ByteFormatter.string(bytes: 1_500_000_000)
        XCTAssertTrue(s.contains("GB"))
    }

    func testKilobyteExact() {
        XCTAssertEqual(ByteFormatter.string(bytes: 1024), "1.0 KB")
    }

    func testMegabyteExact() {
        XCTAssertEqual(ByteFormatter.string(bytes: 1_048_576), "1.0 MB")
    }

    func testRateSlow() {
        let s = ByteFormatter.rateString(bytesPerSecond: 50)
        XCTAssertEqual(s, "50 B/s")
    }

    func testRateKBs() {
        let s = ByteFormatter.rateString(bytesPerSecond: 2048)
        XCTAssertEqual(s, "2.0 KB/s")
    }

    func testRateMBs() {
        let s = ByteFormatter.rateString(bytesPerSecond: 3_145_728)
        XCTAssertEqual(s, "3.0 MB/s")
    }

    func testRateZero() {
        XCTAssertEqual(ByteFormatter.rateString(bytesPerSecond: 0), "0 B/s")
    }
}
