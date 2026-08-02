import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIBackgroundAvailabilityTests {
    @Test
    func `disabled Keychain allows cold background Auto usage without an established marker`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
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
    func `enabled Keychain rejects cold background Auto usage without an established marker`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
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
    func `disabled Keychain allows background Auto after foreground availability is established`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo", environment: context.env)
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
    func `background Auto CLI keeps prompt policy after foreground availability is established`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo", environment: context.env)
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
    func `background Auto CLI uses foreground availability with explicit prompt opt in`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo", environment: context.env)
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
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
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
    func `failed disabled Keychain exception revokes later background Auto usage`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw ExpectedFetchError.failed
            }

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                            await #expect(throws: ExpectedFetchError.self) {
                                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                                    try await strategy.fetch(context)
                                }
                            }
                            #expect(await !strategy.isAvailable(context))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `cancelled disabled Keychain exception keeps later background Auto usage available`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)
        let fetchOverride: @Sendable (String, TimeInterval, Bool) async throws
            -> ClaudeStatusSnapshot = { _, _, _ in
                throw CancellationError()
            }

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                            await #expect(throws: CancellationError.self) {
                                try await ClaudeStatusProbe.$fetchOverride.withValue(fetchOverride) {
                                    try await strategy.fetch(context)
                                }
                            }
                            #expect(await strategy.isAvailable(context))
                        }
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

    @Test
    func `background Auto availability does not cross config profiles`() async throws {
        let strategy = self.makeStrategy()
        let profileA = try self.makeProfile(accountID: "account-a")
        let profileB = try self.makeProfile(accountID: "account-b")
        defer {
            try? FileManager.default.removeItem(at: profileA.root)
            try? FileManager.default.removeItem(at: profileB.root)
        }
        let contextA = self.makeContext(environment: profileA.environment)
        let contextB = self.makeContext(environment: profileB.environment)

        await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo", environment: contextA.env)
            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(contextA))
                            #expect(await !strategy.isAvailable(contextB))
                        }
                    }
                }
            }
        }
    }

    @Test
    func `background Auto availability does not cross active account changes`() async throws {
        let strategy = self.makeStrategy()
        let profile = try self.makeProfile(accountID: "account-a")
        defer { try? FileManager.default.removeItem(at: profile.root) }
        let context = self.makeContext(environment: profile.environment)

        try await ClaudeCLIBackgroundAvailability.withIsolatedStoreForTesting {
            ClaudeCLIBackgroundAvailability.establish(binary: "/bin/echo", environment: context.env)
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                    try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting("/bin/echo") {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            #expect(await strategy.isAvailable(context))
                            try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
                                .write(to: profile.configURL, options: .atomic)
                            #expect(await !strategy.isAvailable(context))
                            try FileManager.default.removeItem(at: profile.configURL)
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
            includePrepaidBalance: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0),
            hasWebFallback: false)
    }

    private enum ExpectedFetchError: Error {
        case failed
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        environment: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: environment),
            browserDetection: browserDetection)
    }

    private func makeProfile(accountID: String) throws -> (
        root: URL,
        configURL: URL,
        environment: [String: String])
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-background-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"\#(accountID)"}}"#.utf8)
            .write(to: configURL, options: .atomic)
        return (
            root: root,
            configURL: configURL,
            environment: ["CLAUDE_CONFIG_DIR": root.path])
    }
}
