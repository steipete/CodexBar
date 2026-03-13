import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)

/// Regression tests for #474: verify that CLI timeout errors trigger fallback
/// to the web strategy instead of stalling the refresh cycle.
@Suite
struct AugmentCLIFetchStrategyFallbackTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(sourceMode: ProviderSourceMode = .auto) -> ProviderFetchContext {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    // SubprocessRunnerError is not an AuggieCLIError, so it hits the default
    // fallback=true path — the desired behavior for infrastructure errors.

    @Test
    func timeoutErrorFallsBackToWeb() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.timedOut("auggie-account-status")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }

    @Test
    func binaryNotFoundFallsBackToWeb() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.binaryNotFound("/usr/local/bin/auggie")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }

    @Test
    func launchFailedFallsBackToWeb() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.launchFailed("permission denied")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }

    @Test
    func notAuthenticatedFallsBackToWeb() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        #expect(strategy.shouldFallback(on: AuggieCLIError.notAuthenticated, context: context) == true)
    }

    @Test
    func noOutputFallsBackToWeb() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        #expect(strategy.shouldFallback(on: AuggieCLIError.noOutput, context: context) == true)
    }

    @Test
    func parseErrorDoesNotFallBack() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        #expect(strategy.shouldFallback(on: AuggieCLIError.parseError("bad data"), context: context) == false)
    }

    @Test
    func nonZeroExitFallsBackToWeb() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.nonZeroExit(code: 1, stderr: "crash")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }
}

#endif
