import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIBackgroundAvailabilityTests {
    @Test
    func `background Auto CLI is unavailable before a user establishes availability`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext()

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await !strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `disabled Keychain allows background Auto after foreground availability is established`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext()

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo")
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `background Auto CLI keeps prompt policy after foreground availability is established`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext()

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo")
            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await !strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `background Auto CLI uses foreground availability with explicit prompt opt in`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext()

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo")
            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: ClaudeOAuthKeychainPromptMode.allCases)
    func `background explicit OAuth never reaches interactive CLI`(promptMode: ClaudeOAuthKeychainPromptMode) async {
        let strategy = self.makeStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo")
            await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
                await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        #expect(await !strategy.isAvailable(context))
                    }
                }
            }
        }
    }

    @Test
    func `user initiated explicit OAuth retains interactive CLI recovery`() async {
        let strategy = self.makeStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                #expect(await strategy.isAvailable(context))
            }
        }
    }

    private func makeStrategy() -> ClaudeCLIFetchStrategy {
        ClaudeCLIFetchStrategy(
            useWebExtras: false,
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
    }

    private func makeContext(sourceMode: ProviderSourceMode = .auto) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
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
