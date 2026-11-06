import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct LegacyCredentialRefreshRecoveryTests {
    @Test
    func `manual refresh retries only the selected provider without deleting legacy credentials`() async throws {
        let fixture = try self.fixture()
        defer { fixture.removeFiles() }
        let initialZaiLoads = fixture.zai.loadCount
        let initialCopilotLoads = fixture.copilot.loadCount
        #expect(fixture.zai.interactions == [.background])
        fixture.zai.throwOnLoad = false
        fixture.copilot.throwOnLoad = false

        await self.manual {
            ProviderInteractionContext.$current.withValue(.background) {
                fixture.usage.prepareRefreshState(for: .zai)
            }
            #expect(fixture.zai.loadCount == initialZaiLoads)
            fixture.usage.prepareRefreshState(for: .zai)
        }
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == "fixture-zai-token")
        #expect(try fixture.settings.configStore.load()?.providerConfig(for: .zai)?.apiKey == "fixture-zai-token")
        #expect(fixture.zai.loadCount == initialZaiLoads + 1)
        #expect(fixture.copilot.loadCount == initialCopilotLoads)
        #expect(fixture.zai.clearCount == 0)
        #expect(!fixture.defaults.bool(forKey: "codexbar.legacySecretsMigrationCompleted"))

        fixture.settings.updateProviderConfig(provider: .zai) { $0.apiKey = nil }
        fixture.settings.updateProviderConfig(provider: .copilot) { $0.enabled = false }
        await self.manual { fixture.usage.prepareRefreshState() }
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == nil)
        #expect(fixture.zai.loadCount == initialZaiLoads + 1)
        #expect(fixture.copilot.loadCount == initialCopilotLoads)
    }

    @Test
    func `manual recovery preserves config edits made while the credential read returns`() async throws {
        let fixture = try self.fixture()
        defer { fixture.removeFiles() }
        fixture.zai.throwOnLoad = false
        fixture.zai.beforeReturn = { [settings = fixture.settings] in
            MainActor.assumeIsolated {
                settings.updateProviderConfig(provider: .zai) { $0.apiKey = "new-user-token" }
                settings.updateProviderConfig(provider: .copilot) { $0.apiKey = "other-user-token" }
            }
        }
        await self.manual { fixture.usage.prepareRefreshState(for: .zai) }
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == "new-user-token")
        #expect(fixture.settings.providerConfig(for: .copilot)?.apiKey == "other-user-token")
        #expect(fixture.zai.clearCount == 0)
    }

    @Test
    func `disabled provider recovery needs permission while global refresh stays filtered`() async throws {
        let fixture = try self.fixture()
        defer { fixture.removeFiles() }
        fixture.zai.throwOnLoad = false
        fixture.settings.updateProviderConfig(provider: .zai) { $0.enabled = false }
        fixture.usage._test_providerRefreshOverride = { _ in }
        let reads = fixture.zai.loadCount
        await self.manual {
            fixture.usage.prepareRefreshState(allowDisabled: true)
            await fixture.usage.refreshProvider(.zai)
        }
        #expect(fixture.zai.loadCount == reads)
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == nil)
        await self.manual {
            await fixture.usage.refreshProvider(.zai, allowDisabled: true)
        }
        #expect(fixture.zai.loadCount == reads + 1)
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == "fixture-zai-token")
        #expect(fixture.settings.providerConfig(for: .zai)?.enabled == false)
    }

    @Test
    func `cleared existing fields and completed migrations do not resurrect legacy credentials`() async throws {
        let fixture = try self.fixture(existingZaiToken: "configured-token")
        defer { fixture.removeFiles() }
        let initialZaiLoads = fixture.zai.loadCount
        let initialCopilotLoads = fixture.copilot.loadCount
        fixture.zai.throwOnLoad = false
        fixture.copilot.throwOnLoad = false
        fixture.settings.updateProviderConfig(provider: .zai) { $0.apiKey = nil }
        await self.manual { fixture.usage.prepareRefreshState(for: .zai) }
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == nil)
        #expect(fixture.zai.loadCount == initialZaiLoads)
        fixture.defaults.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
        await self.manual { fixture.usage.prepareRefreshState(for: .copilot) }
        #expect(fixture.settings.providerConfig(for: .copilot)?.apiKey == nil)
        #expect(fixture.copilot.loadCount == initialCopilotLoads)
    }

    @Test
    func `cancelled recovery cannot publish the returned credential`() async throws {
        let fixture = try self.fixture()
        defer { fixture.removeFiles() }
        fixture.zai.throwOnLoad = false
        fixture.zai.beforeReturn = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { @MainActor in
            await self.manual { fixture.usage.prepareRefreshState(for: .zai) }
        }
        await task.value
        #expect(fixture.settings.providerConfig(for: .zai)?.apiKey == nil)
        #expect(try fixture.settings.configStore.load()?.providerConfig(for: .zai)?.apiKey == nil)
        #expect(fixture.zai.clearCount == 0)
    }

    @Test
    func `recovery follows the selected source including legacy CLI web fallbacks`() async throws {
        let routes: [(UsageProvider, ProviderSourceMode, ProviderCookieSource, Bool)] = [
            (.amp, .cli, .manual, false), (.amp, .web, .manual, true),
            (.factory, .api, .manual, false), (.factory, .cli, .manual, true),
            (.cursor, .cli, .manual, true), (.augment, .cli, .manual, true),
            (.minimax, .api, .manual, false), (.kimi, .api, .manual, true),
            (.opencode, .web, .off, false), (.opencode, .web, .auto, false),
            (.opencode, .web, .manual, true),
        ]
        for (provider, source, cookieSource, shouldRecover) in routes {
            let fixture = try self.fixture(cookieToken: "session=fixture")
            defer { fixture.removeFiles() }
            fixture.settings.updateProviderConfig(provider: provider) {
                $0.enabled = true
                $0.source = source
                $0.cookieSource = cookieSource
            }
            let reads = fixture.cookies.loadCount
            fixture.cookies.throwOnLoad = false
            await self.manual { fixture.usage.prepareRefreshState(for: provider) }
            #expect(fixture.cookies.loadCount == reads + (shouldRecover ? 1 : 0))
            #expect(fixture.settings.providerConfig(for: provider)?.cookieHeader ==
                (shouldRecover ? "session=fixture" : nil))
        }
    }

    @Test
    func `Codex and Claude cookie recovery respects optional web settings`() async throws {
        let fixture = try self.fixture(cookieToken: "session=fixture")
        defer { fixture.removeFiles() }
        fixture.cookies.throwOnLoad = false
        for provider in [UsageProvider.codex, .claude] {
            fixture.settings.updateProviderConfig(provider: provider) {
                $0.enabled = true
                $0.source = .oauth
                $0.cookieSource = .manual
            }
        }
        fixture.settings.openAIWebAccessEnabled = false
        fixture.settings.claudeWebExtrasEnabled = false
        fixture.settings.showOptionalCreditsAndExtraUsage = false
        let reads = fixture.cookies.loadCount
        await self.manual {
            fixture.usage.prepareRefreshState(for: .codex)
            fixture.usage.prepareRefreshState(for: .claude)
        }
        #expect(fixture.cookies.loadCount == reads)
        fixture.settings.openAIWebAccessEnabled = true
        fixture.settings.showOptionalCreditsAndExtraUsage = true
        await self.manual {
            fixture.usage.prepareRefreshState(for: .codex)
            fixture.usage.prepareRefreshState(for: .claude)
        }
        #expect(fixture.settings.providerConfig(for: .codex)?.cookieHeader == "session=fixture")
        #expect(fixture.settings.providerConfig(for: .claude)?.cookieHeader == "session=fixture")
    }

    private func manual(_ operation: () async -> Void) async {
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ProviderSettingsRefreshInteraction.perform { await operation() }
        }
    }

    private func fixture(existingZaiToken: String? = nil, cookieToken: String? = nil) throws -> Fixture {
        let defaults = InMemoryUserDefaults()
        let configStore = testConfigStore(suiteName: "legacy-refresh-\(UUID().uuidString)")
        var config = CodexBarConfig.makeDefault()
        for index in config.providers.indices {
            config.providers[index].enabled = false
        }
        config.setProviderConfig(ProviderConfig(id: .zai, enabled: true, apiKey: existingZaiToken))
        config.setProviderConfig(ProviderConfig(id: .copilot, enabled: true))
        try configStore.save(config)
        let zai = RecoveryLegacySecretStore(token: "fixture-zai-token")
        let copilot = RecoveryLegacySecretStore(token: "fixture-copilot-token")
        let absent = RecoveryLegacySecretStore(token: nil, throwOnLoad: false)
        let cookies = RecoveryLegacySecretStore(token: cookieToken, throwOnLoad: cookieToken != nil)
        let settings = ProviderInteractionContext.$current.withValue(.userInitiated) {
            SettingsStore(
                userDefaults: defaults,
                configStore: configStore,
                zaiTokenStore: zai,
                syntheticTokenStore: absent,
                codexCookieStore: cookies,
                claudeCookieStore: cookies,
                cursorCookieStore: cookies,
                opencodeCookieStore: cookies,
                factoryCookieStore: cookies,
                minimaxCookieStore: cookies,
                minimaxAPITokenStore: absent,
                kimiTokenStore: cookies,
                augmentCookieStore: cookies,
                ampCookieStore: cookies,
                copilotTokenStore: copilot,
                tokenAccountStore: InMemoryTokenAccountStore(),
                keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }),
                performInitialProviderDetection: false)
        }
        let usage = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return Fixture(
            defaults: defaults, settings: settings, usage: usage, zai: zai, copilot: copilot, cookies: cookies)
    }

    @MainActor
    private struct Fixture {
        let defaults: InMemoryUserDefaults
        let settings: SettingsStore
        let usage: UsageStore
        let zai: RecoveryLegacySecretStore
        let copilot: RecoveryLegacySecretStore
        let cookies: RecoveryLegacySecretStore

        func removeFiles() {
            try? FileManager.default.removeItem(at: self.settings.configStore.fileURL.deletingLastPathComponent())
        }
    }
}

private final class RecoveryLegacySecretStore: ZaiTokenStoring, SyntheticTokenStoring, CookieHeaderStoring,
    MiniMaxCookieStoring, MiniMaxAPITokenStoring, KimiTokenStoring, CopilotTokenStoring, @unchecked Sendable
{
    enum Failure: Error { case unreadable }

    var throwOnLoad: Bool
    var beforeReturn: (@Sendable () -> Void)?
    private let token: String?
    private(set) var loadCount = 0
    private(set) var clearCount = 0
    private(set) var interactions: [ProviderInteraction] = []

    init(token: String?, throwOnLoad: Bool = true) {
        self.token = token
        self.throwOnLoad = throwOnLoad
    }

    func loadToken() throws -> String? {
        self.loadCount += 1
        self.interactions.append(ProviderInteractionContext.current)
        if self.throwOnLoad { throw Failure.unreadable }
        self.beforeReturn?()
        return self.token
    }

    func loadCookieHeader() throws -> String? { try self.loadToken() }
    func storeToken(_ token: String?) { if token == nil { self.clearCount += 1 } }
    func storeCookieHeader(_ header: String?) { self.storeToken(header) }
}
