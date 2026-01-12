import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct TTYIntegrationTests {
    @Test
    func codexRPCUsageLive() async throws {
        let fetcher = UsageFetcher()
        do {
            let snapshot = try await fetcher.loadLatestUsage()
            guard let primary = snapshot.primary else {
                return
            }
            let hasData = primary.usedPercent >= 0 && (snapshot.secondary?.usedPercent ?? 0) >= 0
            #expect(hasData)
        } catch UsageError.noRateLimitsFound {
            return
        } catch {
            return
        }
    }

    @Test
    func claudeTTYUsageProbeLive() async throws {
        guard TTYCommandRunner.which("claude") != nil else {
            return
        }

        let fetcher = ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0), dataSource: .cli)

        var shouldAssert = true
        do {
            let snapshot = try await fetcher.loadLatestUsage()
            #expect(snapshot.primary.remainingPercent >= 0)
            // Weekly is absent for some enterprise accounts.
        } catch ClaudeUsageError.parseFailed(_) {
            shouldAssert = false
        } catch ClaudeStatusProbeError.parseFailed(_) {
            shouldAssert = false
        } catch ClaudeUsageError.claudeNotInstalled {
            shouldAssert = false
        } catch ClaudeStatusProbeError.timedOut {
            shouldAssert = false
        } catch let TTYCommandRunner.Error.launchFailed(message) where message.contains("login") {
            shouldAssert = false
        } catch {
            shouldAssert = false
        }

        await ClaudeCLISession.shared.reset()
        if !shouldAssert { return }
    }
}
