import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CommandCodeProviderTests {
    private final class CookieAttemptRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var cookieHeaders: [String] = []

        func append(_ cookieHeader: String) {
            self.lock.withLock {
                self.cookieHeaders.append(cookieHeader)
            }
        }

        func snapshot() -> [String] {
            self.lock.withLock { self.cookieHeaders }
        }
    }

    @Test
    func `explicit API source selects the configured key without cookie discovery`() async throws {
        let detection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["COMMAND_CODE_API_KEY": "fixture-command-key"],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection)
        let strategies = await CommandCodeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.map(\.id) == ["commandcode.api"])
        let strategy = try #require(strategies.first)
        #expect(strategy.kind == .apiToken)
        #expect(await strategy.isAvailable(context))
    }

    @Test
    func `descriptor metadata is correct`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .commandcode)

        #expect(descriptor.metadata.displayName == "Command Code")
        #expect(descriptor.metadata.dashboardURL == "https://commandcode.ai/studio")
        #expect(descriptor.metadata.subscriptionDashboardURL == "https://commandcode.ai/settings/billing")
        #expect(descriptor.metadata.cliName == "commandcode")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-commandcode")
        #expect(descriptor.branding.iconStyle == .commandcode)
        #expect(descriptor.metadata.sessionLabel == "5-hour")
        #expect(descriptor.metadata.weeklyLabel == "Weekly")
        #expect(descriptor.metadata.opusLabel == "Monthly")
        #expect(descriptor.metadata.supportsOpus)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api, .web])
    }

    @Test(arguments: [false, true])
    func `automatic source prefers a configured key and otherwise uses cookies`(hasKey: Bool) async {
        let detection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: hasKey ? ["COMMAND_CODE_API_KEY": "fixture-command-key"] : [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection)
        let strategies = await CommandCodeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.map(\.id) == [hasKey ? "commandcode.api" : "commandcode.web"])
    }

    @Test
    func `manual cookie makes web strategy available`() async {
        let context = self.makeContext(cookieSource: .manual, manualCookieHeader: "session=manual")

        #expect(await CommandCodeWebFetchStrategy().isAvailable(context))
    }

    @Test(arguments: [
        ("bare-value", "__Secure-commandcode_prod_.session_token=bare-value"),
        (" \"bare-value\" ", "__Secure-commandcode_prod_.session_token=bare-value"),
        (
            "Cookie: __Secure-commandcode_prod_.session_token=token; extra=keep",
            "__Secure-commandcode_prod_.session_token=token; extra=keep"),
        ("__Secure-better-auth.session_token=legacy", "__Secure-better-auth.session_token=legacy"),
        ("session=explicit", "session=explicit"),
    ])
    func `manual fetch normalizes bare tokens and preserves explicit cookie headers`(
        input: String,
        expected: String) async throws
    {
        let recorder = CookieAttemptRecorder()
        let strategy = CommandCodeWebFetchStrategy(
            usageLoader: { cookieHeader in
                recorder.append(cookieHeader)
                return Self.snapshot()
            },
            sessionLoader: {
                Issue.record("Manual input must not import browser sessions")
                return []
            })

        _ = try await strategy.fetch(self.makeContext(cookieSource: .manual, manualCookieHeader: input))

        #expect(recorder.snapshot() == [expected])
    }

    @Test
    func `automatic cookie fetch retries Vivaldi after stale earlier browser session`() async throws {
        let service = "com.steipete.codexbar.tests.commandcode-retry.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                let recorder = CookieAttemptRecorder()
                let strategy = CommandCodeWebFetchStrategy(
                    usageLoader: { cookieHeader in
                        recorder.append(cookieHeader)
                        guard cookieHeader == "session=vivaldi" else {
                            throw CommandCodeUsageError.invalidCredentials
                        }
                        return Self.snapshot()
                    },
                    sessionLoader: {
                        [
                            CommandCodeResolvedSession(cookieHeader: "session=stale", sourceLabel: "Chrome Default"),
                            CommandCodeResolvedSession(
                                cookieHeader: "session=vivaldi",
                                sourceLabel: "Vivaldi Default"),
                        ]
                    })

                let result = try await strategy.fetch(self.makeContext(cookieSource: .auto))

                #expect(recorder.snapshot() == ["session=stale", "session=vivaldi"])
                #expect(result.sourceLabel == "Vivaldi Default")
            }
        }
    }

    @Test
    func `automatic cookie fetch does not hide non-auth failure with later session`() async {
        let service = "com.steipete.codexbar.tests.commandcode-failure.\(UUID().uuidString)"
        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                let recorder = CookieAttemptRecorder()
                let strategy = CommandCodeWebFetchStrategy(
                    usageLoader: { cookieHeader in
                        recorder.append(cookieHeader)
                        throw CommandCodeUsageError.networkError("offline")
                    },
                    sessionLoader: {
                        [
                            CommandCodeResolvedSession(cookieHeader: "session=first", sourceLabel: "Chrome Default"),
                            CommandCodeResolvedSession(
                                cookieHeader: "session=vivaldi",
                                sourceLabel: "Vivaldi Default"),
                        ]
                    })

                await #expect(throws: CommandCodeUsageError.networkError("offline")) {
                    try await strategy.fetch(self.makeContext(cookieSource: .auto))
                }
                #expect(recorder.snapshot() == ["session=first"])
            }
        }
    }

    @Test
    func `validated browser session persists for subsequent automatic fetch`() async throws {
        let provider = UsageProvider.commandcode
        let service = "com.steipete.codexbar.tests.commandcode-cache.\(UUID().uuidString)"
        let recorder = CookieAttemptRecorder()
        let browserLoadRecorder = CookieAttemptRecorder()

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                let gate = try #require(CookieHeaderCache.beginRefreshReadSuppression(provider: provider))
                defer { CookieHeaderCache.endRefreshReadSuppression(gate) }
                let strategy = CommandCodeWebFetchStrategy(
                    usageLoader: { cookieHeader in
                        recorder.append(cookieHeader)
                        return Self.snapshot()
                    },
                    sessionLoader: {
                        browserLoadRecorder.append("load")
                        return [CommandCodeResolvedSession(
                            cookieHeader: "session=validated",
                            sourceLabel: "Chrome Default")]
                    })

                _ = try await strategy.fetch(self.makeContext(cookieSource: .auto))
                #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "session=validated")
                #expect(CookieHeaderCache.commitRefreshReadSuppression(gate) == CookieRefreshCommitSummary(
                    stagedCount: 1,
                    committedCount: 1,
                    failedCount: 0))

                _ = try await strategy.fetch(self.makeContext(cookieSource: .auto))

                #expect(browserLoadRecorder.snapshot() == ["load"])
                #expect(recorder.snapshot() == ["session=validated", "session=validated"])
                #expect(CookieHeaderCache.load(provider: provider)?.sourceLabel == "Chrome Default")
            }
        }
    }

    @MainActor
    @Test
    func `implementation is registered`() {
        #expect(ProviderCatalog.implementation(for: .commandcode) != nil)
    }

    private static func snapshot() -> CommandCodeUsageSnapshot {
        CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 10,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            plan: nil,
            billingPeriodEnd: nil,
            subscriptionStatus: nil)
    }

    private func makeContext(
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let settings = ProviderSettingsSnapshot.make(
            commandcode: .init(cookieSource: cookieSource, manualCookieHeader: manualCookieHeader))
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
