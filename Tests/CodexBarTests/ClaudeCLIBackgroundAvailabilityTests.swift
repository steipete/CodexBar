import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIBackgroundAvailabilityTests {
    @Test
    func `background Auto CLI remains available when Keychain access is disabled`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext()

        await KeychainAccessGate.withTaskOverrideForTesting(true) {
            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        // Auth-status would fail if probed; disabled-Keychain boot must not depend on it.
                        await ClaudeCLIAuthStatusProbe.withResultOverrideForTesting(false) {
                            #expect(await strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `background Auto CLI stays gated when Keychain enabled and prompt is only on user action`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext()

        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        await ClaudeCLIAuthStatusProbe.withResultOverrideForTesting(true) {
                            #expect(await !strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    private func makeStrategy() -> ClaudeCLIFetchStrategy {
        ClaudeCLIFetchStrategy(
            useWebExtras: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
    }

    private func makeContext() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
