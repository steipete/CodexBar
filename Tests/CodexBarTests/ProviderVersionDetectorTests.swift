import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ProviderVersionDetectorTests {
    @Test
    func runForTestingReturnsFirstLineForFastCommand() {
        let output = ProviderVersionDetector.runForTesting(path: "/bin/sh", args: ["-c", "printf '1.2.3\\nextra'"])
        #expect(output == "1.2.3")
    }

    @Test
    func runForTestingTimesOutLongRunningCommand() {
        let start = Date()
        let output = ProviderVersionDetector.runForTesting(path: "/bin/sh", args: ["-c", "sleep 5"])
        let elapsed = Date().timeIntervalSince(start)

        #expect(output == nil)
        #expect(elapsed < 4.5)
    }
}
