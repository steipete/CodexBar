import XCTest
@testable import CodexBarCore

final class ProviderVersionDetectorTests: XCTestCase {
    func test_run_returnsFirstLineForSuccessfulCommand() {
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "printf 'gemini 1.2.3\\nextra\\n'"],
            timeout: 1.0)

        XCTAssertEqual(version, "gemini 1.2.3")
    }

    func test_run_returnsNilAfterTimeout() {
        let start = Date()
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "sleep 5"],
            timeout: 0.1)
        let duration = Date().timeIntervalSince(start)

        XCTAssertNil(version)
        XCTAssertLessThan(duration, 2.0)
    }
}
