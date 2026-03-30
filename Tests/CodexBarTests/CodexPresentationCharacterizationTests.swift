import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexPresentationCharacterizationTests {
    @Test
    func `weekly only Codex menu rendering omits session row`() {
        let settings = self.makeSettingsStore(suite: "CodexPresentationCharacterizationTests-weekly-only")
        settings.statusChecksEnabled = false

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: "Apr 6, 2026"),
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "free")),
            provider: .codex)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false,
            includeContextualActions: false)

        let lines = self.textLines(from: descriptor)
        #expect(!lines.contains(where: { $0.hasPrefix("Session:") }))
        #expect(lines.contains(where: { $0.hasPrefix("Weekly:") }))
    }

    @Test
    func `Codex menu does not surface identity from another provider snapshot`() {
        let settings = self.makeSettingsStore(suite: "CodexPresentationCharacterizationTests-provider-silo")
        settings.statusChecksEnabled = false

        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "free")),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: "claude@example.com",
                    accountOrganization: nil,
                    loginMethod: "max")),
            provider: .claude)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false,
            includeContextualActions: false)

        let lines = self.textLines(from: descriptor)
        #expect(lines.contains("Account: codex@example.com"))
        #expect(lines.contains("Plan: Free"))
        #expect(!lines.contains("Account: claude@example.com"))
        #expect(!lines.contains("Plan: Max"))
    }

    @Test
    func `managed OpenAI web targeting uses active managed Codex identity and scope`() {
        let settings = self.makeSettingsStore(suite: "CodexPresentationCharacterizationTests-managed-openai-web")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == managedAccount.email)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == .managedAccount(managedAccount.id))
    }

    @Test
    func `live OpenAI web targeting uses live Codex identity without managed scope`() {
        let settings = self.makeSettingsStore(suite: "CodexPresentationCharacterizationTests-live-openai-web")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveAccount = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveAccount
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": liveAccount.codexHomePath]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == liveAccount.email)
        #expect(store.codexAccountEmailForOpenAIDashboard() != managedAccount.email)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
    }

    @Test
    func `same email managed and live Codex resolves to live for OpenAI web targeting`() {
        let settings = self.makeSettingsStore(suite: "CodexPresentationCharacterizationTests-same-email-prefers-live")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "person@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveAccount = ObservedSystemCodexAccount(
            email: "PERSON@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": liveAccount.codexHomePath]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(settings.codexResolvedActiveSource == .liveSystem)
        #expect(store.codexAccountEmailForOpenAIDashboard() == "person@example.com")
        #expect(store.codexAccountEmailForOpenAIDashboard() != liveAccount.email)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
    }

    @Test
    func `live OpenAI web targeting does not reuse stale managed Codex snapshot identity`() {
        let settings = self.makeSettingsStore(suite: "CodexPresentationCharacterizationTests-stale-managed-snapshot")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-presentation-openai-web-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: managedAccount.email,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .codex)

        #expect(store.codexAccountEmailForOpenAIDashboard() == nil)
        #expect(store.codexAccountEmailForOpenAIDashboard() != managedAccount.email)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_activeManagedCodexAccount = nil
        settings._test_activeManagedCodexRemoteHomePath = nil
        settings._test_unreadableManagedCodexAccountStore = false
        settings._test_managedCodexAccountStoreURL = nil
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = nil
        return settings
    }

    private func textLines(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
    }
}
