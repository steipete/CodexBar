import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct ProviderInstanceIdentityCharacterizationTests {
    @Test
    func `config provider IDs and enablement encode as their existing bare strings`() throws {
        let input = Data(#"{"version":1,"providers":[{"id":"claude","enabled":true},{"id":"codex","enabled":false}]}"#
            .utf8)
        let config = try JSONDecoder().decode(CodexBarConfig.self, from: input)

        #expect(config.orderedProviders() == [.claude, .codex])
        #expect(config.enabledProviders() == [.claude])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(config)
        let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
        #expect(encodedJSON ==
            #"{"providers":[{"enabled":true,"id":"claude"},{"enabled":false,"id":"codex"}],"version":1}"#)
    }

    @Test
    func `history uses the provider raw value for its filename and leaves payload shape unchanged`() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderInstanceIdentityCharacterizationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let history = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 0),
                    usedPercent: 12,
                    resetsAt: nil),
            ])
        let store = PlanUtilizationHistoryStore(directoryURL: directoryURL)
        store.save([.claude: PlanUtilizationHistoryBuckets(unscoped: [history])])

        let filenames = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        #expect(filenames == ["claude.json"])
        let data = try Data(contentsOf: directoryURL.appendingPathComponent("claude.json"))
        let encodedJSON = try #require(String(data: data, encoding: .utf8))
        let expectedJSON = #"{"accounts":{},"sessionEquivalentWindowPairIdentities":{},"unscoped":["# +
            #"{"entries":[{"capturedAt":"1970-01-01T00:00:00Z","usedPercent":12}],"# +
            #""name":"session","windowMinutes":300}],"version":1}"#
        #expect(encodedJSON == expectedJSON)
        #expect(store.load().keys.sorted(by: { $0.rawValue < $1.rawValue }) == [.claude])
    }

    @Test
    func `provider config ordering remains the menu and status ordering contract`() {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .gemini, enabled: true),
            ProviderConfig(id: .claude, enabled: false),
            ProviderConfig(id: .codex, enabled: true),
        ])

        #expect(config.orderedProviders() == [.gemini, .claude, .codex])
        #expect(config.enabledProviders() == [.gemini, .codex])
    }

    @MainActor
    @Test
    func `settings pane selection persists the provider prefixed raw value`() throws {
        let suiteName = "ProviderInstanceIdentityCharacterizationTests-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let selection = PreferencesSelection(userDefaults: defaults)
        selection.pane = .provider(.claude)

        #expect(defaults.string(forKey: PreferencesSelection.paneDefaultsKey) == "provider:claude")
        #expect(PreferencesSelection(userDefaults: defaults).pane == .provider(.claude))
    }

    @Test
    func `keychain cache accounts retain provider raw values`() {
        #expect(KeychainCacheStore.Key.cookie(provider: .claude).account == "cookie.claude")
        #expect(KeychainCacheStore.Key.cookie(provider: .claude, scopeIdentifier: "profile").account ==
            "cookie.claude.profile")
        #expect(KeychainCacheStore.Key.oauth(provider: .claude).account == "oauth.claude")
    }

    @Test
    func `provider identity encodes its provider as the existing bare string`() throws {
        let snapshot = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "oauth")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(snapshot)
        let encodedJSON = try #require(String(data: encoded, encoding: .utf8))

        #expect(encodedJSON ==
            #"{"accountEmail":"user@example.com","loginMethod":"oauth","providerID":"claude"}"#)
    }

    @Test
    func `widget snapshot provider IDs retain their payload format and order`() throws {
        let entries = [UsageProvider.claude, .codex].map { provider in
            WidgetSnapshot.ProviderEntry(
                provider: provider,
                updatedAt: Date(timeIntervalSinceReferenceDate: 0),
                primary: nil,
                secondary: nil,
                tertiary: nil,
                creditsRemaining: nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: nil,
                dailyUsage: [])
        }
        let snapshot = WidgetSnapshot(
            entries: entries,
            enabledProviders: [.claude, .codex],
            generatedAt: Date(timeIntervalSinceReferenceDate: 0))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(snapshot)
        let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
        let expectedJSON = #"{"enabledProviders":["claude","codex"],"entries":["# +
            #"{"dailyUsage":[],"provider":"claude","updatedAt":0},"# +
            #"{"dailyUsage":[],"provider":"codex","updatedAt":0}],"# +
            #""generatedAt":0,"usageBarsShowUsed":false}"#

        #expect(encodedJSON == expectedJSON)
    }

    @Test
    func `CLI provider payload keeps the provider raw string`() {
        let payload = ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: "oauth",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)

        let expected = """
        [
          {
            "provider" : "claude",
            "source" : "oauth"
          }
        ]
        """
        #expect(CodexBarCLI.encodeJSON([payload], pretty: true) == expected)
    }
}
