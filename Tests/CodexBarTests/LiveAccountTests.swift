import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite("Live RPC account checks", .serialized)
struct LiveAccountTests {
    @Test(.disabled("Set LIVE_TEST=1 to run live Codex account checks."))
    func codexAccountEmailIsPresent() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_TEST"] == "1" else { return }

        let fetcher = UsageFetcher()
        let usage = try await fetcher.loadLatestUsage()
        guard let email = usage.accountEmail(for: .codex) else {
            Issue.record("Account email missing from RPC usage snapshot")
            return
        }

        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        let regex = try Regex(pattern)
        #expect(email.contains(regex), "Email did not match pattern: \(email)")
    }
}
