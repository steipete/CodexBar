import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
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

    @Test
    func `saved sessions preserve their HTTP credentials and rejected selections never fall back`() async throws {
        let service = "com.steipete.codexbar.tests.commandcode-accounts.\(UUID())"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
                    CookieHeaderCache.store(
                        provider: .commandcode, cookieHeader: "session=ambient", sourceLabel: "Cached account")
                    let inputs = [
                        ("\"fixture-a\"", "__Secure-commandcode_prod_.session_token=fixture-a"),
                        (
                            "Cookie: __Secure-commandcode_prod_.session_token=fixture-b; extra=keep",
                            "__Secure-commandcode_prod_.session_token=fixture-b; extra=keep"),
                        (
                            "curl 'https://commandcode.ai' -H 'Cookie: session=fixture-c; extra=keep'",
                            "session=fixture-c; extra=keep"),
                    ]
                    let accounts = inputs.enumerated().map { index, input in
                        ProviderTokenAccount(
                            id: UUID(), label: "Fixture \(index)", token: input.0, addedAt: 0, lastUsed: nil)
                    }
                    let cli = try TokenAccountCLIContext(
                        selection: .init(label: nil, index: nil, allAccounts: true),
                        config: CodexBarConfig(providers: [ProviderConfig(
                            id: .commandcode,
                            apiKey: "ambient-api-key",
                            cookieHeader: "session=ambient",
                            cookieSource: .auto,
                            tokenAccounts: .init(version: 1, accounts: accounts, activeIndex: 0))]),
                        verbose: false,
                        baseEnvironment: [:])
                    #expect(try cli.resolvedAccounts(for: .commandcode).map(\.id) == accounts.map(\.id))
                    for (index, account) in accounts.enumerated() {
                        let settings = try #require(cli.settingsSnapshot(for: .commandcode, account: account)?
                            .commandcode)
                        #expect(settings.cookieSource == .manual)
                        #expect(cli.effectiveSourceMode(base: .auto, provider: .commandcode, account: account) == .web)
                        let expected = inputs[index].1
                        let recorder = CookieAttemptRecorder()
                        let transport = ProviderHTTPTransportStub { request in
                            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                            recorder.append(cookie)
                            #expect(cookie == expected)
                            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                            let url = try #require(request.url)
                            let body = url.path.hasSuffix("/credits")
                                ? #"{"credits":{"monthlyCredits":8,"purchasedCredits":0}}"#
                                : """
                                {"success":true,"data":{"id":"fixture-sub","status":"active",\
                                "planId":"individual-go","currentPeriodEnd":"2096-10-02T07:06:40.000Z"}}
                                """
                            return try (Data(body.utf8), #require(HTTPURLResponse(
                                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
                        }
                        let strategy = CommandCodeWebFetchStrategy(
                            usageLoader: { try await CommandCodeUsageFetcher.fetchUsage(
                                cookieHeader: $0,
                                session: transport) },
                            sessionLoader: {
                                Issue.record("A selected account must not import another browser session")
                                return []
                            })
                        let context = self.makeContext(
                            cookieSource: settings.cookieSource,
                            manualCookieHeader: settings.manualCookieHeader,
                            environment: cli.environment(
                                base: ["COMMAND_CODE_API_KEY": "ambient-api-key"],
                                provider: .commandcode,
                                account: account))
                        let strategies = await CommandCodeProviderDescriptor.descriptor.fetchPlan.pipeline
                            .resolveStrategies(context)
                        #expect(strategies.map(\.id) == ["commandcode.web"])
                        let result = try await strategy.fetch(context)
                        #expect(result.sourceLabel == "manual")
                        #expect(!recorder.snapshot().isEmpty)
                    }
                    let rejected = try #require(cli.settingsSnapshot(for: .commandcode, account: accounts[1])?
                        .commandcode)
                    let recorder = CookieAttemptRecorder()
                    let transport = ProviderHTTPTransportStub { request in
                        recorder.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
                        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                        let url = try #require(request.url)
                        return try (Data("{}".utf8), #require(HTTPURLResponse(
                            url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
                    }
                    let strategy = CommandCodeWebFetchStrategy(
                        usageLoader: {
                            try await CommandCodeUsageFetcher.fetchUsage(cookieHeader: $0, session: transport)
                        },
                        sessionLoader: {
                            Issue.record("Rejected selection must not import another browser session")
                            return []
                        })
                    await #expect(throws: CommandCodeUsageError.invalidCredentials) {
                        try await strategy.fetch(self.makeContext(
                            cookieSource: .manual, manualCookieHeader: rejected.manualCookieHeader))
                    }
                    #expect(!recorder.snapshot().isEmpty)
                    #expect(recorder.snapshot().allSatisfy { $0 == inputs[1].1 })
                    #expect(CookieHeaderCache.load(provider: .commandcode)?.cookieHeader == "session=ambient")
                }
            }
        }
    }

    @Test
    func `empty manual sessions cannot use cached or browser accounts`() async throws {
        let service = "com.steipete.codexbar.tests.commandcode-empty.\(UUID())"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: .commandcode, cookieHeader: "session=ambient", sourceLabel: "Cached account")
                let recorder = CookieAttemptRecorder()
                let strategy = CommandCodeWebFetchStrategy(
                    usageLoader: { header in
                        recorder.append(header)
                        return Self.snapshot()
                    },
                    sessionLoader: {
                        recorder.append("browser discovery")
                        return []
                    })
                await #expect(throws: CommandCodeUsageError.missingCredentials) {
                    try await strategy.fetch(self.makeContext(cookieSource: .manual, manualCookieHeader: "Cookie: "))
                }
                #expect(recorder.snapshot().isEmpty)
            }
        }
    }

    @MainActor
    @Test
    func `Command Code can manage subscription session accounts`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "CommandCodeProviderTests-accounts")
        let implementation = CommandCodeProviderImplementation()
        let support = try #require(TokenAccountSupportCatalog.support(for: .commandcode))

        #expect(support.requiresManualCookieSource)
        #expect(support.selectedAccountRequiresManualCookieSource)
        #expect(implementation.tokenAccountsVisibility(
            context: fixture.settingsContext(provider: .commandcode), support: support) == false)

        fixture.settings.addTokenAccount(
            provider: .commandcode,
            label: "Personal",
            token: "session-token")

        #expect(fixture.settings.commandcodeCookieSource == .manual)
        #expect(implementation.tokenAccountsVisibility(
            context: fixture.settingsContext(provider: .commandcode), support: support))

        let contribution = try #require(implementation.settingsSnapshot(context: .init(
            settings: fixture.settings, tokenOverride: nil)))
        let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(snapshot.commandcode?.cookieSource == .manual)
        #expect(snapshot.commandcode?.manualCookieHeader == "session-token")
        let account = try #require(fixture.settings.selectedTokenAccount(for: .commandcode))
        fixture.settings.commandcodeUsageDataSource = .api
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .commandcode) == nil)
        fixture.settings.commandcodeUsageDataSource = .auto
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .commandcode)?.id == account.id)
        fixture.settings.commandcodeCookieSource = .auto
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .commandcode) == nil)
        fixture.settings.setActiveTokenAccountIndex(0, for: .commandcode)
        #expect(fixture.settings.commandcodeCookieSource == .manual)

        fixture.settings.removeTokenAccount(provider: .commandcode, accountID: account.id)
        #expect(fixture.settings.selectedTokenAccount(for: .commandcode) == nil)
        #expect(fixture.settings.commandcodeCookieSource == .manual)
        let cleared = try #require(implementation.settingsSnapshot(context: .init(
            settings: fixture.settings, tokenOverride: nil)))
        let clearedSettings = try #require(ProviderSettingsSnapshot(contributions: [cleared]).commandcode)
        #expect(clearedSettings.cookieSource == .manual)
        #expect((clearedSettings.manualCookieHeader ?? "").isEmpty)
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
        manualCookieHeader: String? = nil,
        environment: [String: String] = [:]) -> ProviderFetchContext
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
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
