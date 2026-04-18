import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)

/// Regression tests for #474: verify that CLI timeout errors trigger fallback
/// to the web strategy instead of stalling the refresh cycle.
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
    func `timeout error falls back to web`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.timedOut("auggie-account-status")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }

    @Test
    func `binary not found falls back to web`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.binaryNotFound("/usr/local/bin/auggie")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }

    @Test
    func `launch failed falls back to web`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.launchFailed("permission denied")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }

    @Test
    func `not authenticated falls back to web`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        #expect(strategy.shouldFallback(on: AuggieCLIError.notAuthenticated, context: context) == true)
    }

    @Test
    func `no output falls back to web`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        #expect(strategy.shouldFallback(on: AuggieCLIError.noOutput, context: context) == true)
    }

    @Test
    func `parse error does not fall back`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        #expect(strategy.shouldFallback(on: AuggieCLIError.parseError("bad data"), context: context) == false)
    }

    @Test
    func `non zero exit falls back to web`() {
        let strategy = AugmentCLIFetchStrategy()
        let context = self.makeContext()
        let error = SubprocessRunnerError.nonZeroExit(code: 1, stderr: "crash")
        #expect(strategy.shouldFallback(on: error, context: context) == true)
    }
}

#endif
