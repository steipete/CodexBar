import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthFetchStrategyAvailabilityTests {
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

    private func makeContext(sourceMode: ProviderSourceMode) -> ProviderFetchContext {
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

    private func expiredRecord(owner: ClaudeOAuthCredentialOwner = .claudeCLI) -> ClaudeOAuthCredentialRecord {
        ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: "expired-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: -60),
                scopes: ["user:profile"],
                rateLimitTier: nil),
            owner: owner,
            source: .cacheKeychain)
    }

    @Test
    func autoModeExpiredCreds_cliAvailable_returnsAvailable() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == true)
    }

    @Test
    func autoModeExpiredCreds_cliUnavailable_returnsUnavailable() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(false) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == false)
    }

    @Test
    func oauthModeExpiredCreds_cliAvailable_returnsAvailable() async {
        let context = self.makeContext(sourceMode: .oauth)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord()) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(true) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == true)
    }

    @Test
    func autoModeExpiredCodexbarCreds_cliUnavailable_stillAvailable() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        let available = await ClaudeOAuthFetchStrategy.$nonInteractiveCredentialRecordOverride
            .withValue(self.expiredRecord(owner: .codexbar)) {
                await ClaudeOAuthFetchStrategy.$claudeCLIAvailableOverride.withValue(false) {
                    await strategy.isAvailable(context)
                }
            }
        #expect(available == true)
    }

    @Test
    func oauthModeDoesNotFallbackAfterOAuthFailure() {
        let context = self.makeContext(sourceMode: .oauth)
        let strategy = ClaudeOAuthFetchStrategy()
        #expect(strategy.shouldFallback(
            on: ClaudeUsageError.oauthFailed("oauth failed"),
            context: context) == false)
    }

    @Test
    func autoModeFallsBackAfterOAuthFailure() {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()
        #expect(strategy.shouldFallback(
            on: ClaudeUsageError.oauthFailed("oauth failed"),
            context: context) == true)
    }

    @Test
    func autoMode_userInitiated_clearsKeychainCooldownGate() async {
        let context = self.makeContext(sourceMode: .auto)
        let strategy = ClaudeOAuthFetchStrategy()

        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

            let now = Date(timeIntervalSince1970: 1000)
            ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now) == false)

            _ = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await strategy.isAvailable(context)
            }

            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now))
        }
    }
}
#endif
