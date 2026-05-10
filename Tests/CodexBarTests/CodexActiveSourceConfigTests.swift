import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct CodexActiveSourceConfigTests {
    @Test
    func `legacy config without codex active source decodes to nil`() throws {
        let legacyJSON = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "codex"
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(
            CodexBarConfig.self,
            from: Data(legacyJSON.utf8))

        #expect(decoded.providerConfig(for: .codex)?.codexActiveSource == nil)
        #expect(decoded.providerConfig(for: .codex)?.quotaWarnings == nil)
    }

    @Test
    func `provider config round trips quota warning overrides`() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .codex,
                    quotaWarnings: QuotaWarningConfig(
                        session: QuotaWarningWindowConfig(thresholds: [10]),
                        weekly: QuotaWarningWindowConfig(thresholds: [50, 20]))),
            ])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)
        let quotaWarnings = try #require(decoded.providerConfig(for: .codex)?.quotaWarnings)

        #expect(quotaWarnings.thresholds(for: .session, global: [80]) == [10])
        #expect(quotaWarnings.thresholds(for: .weekly, global: [80]) == [50, 20])
    }

    @Test
    func `quota warning window enabled defaults stay backward compatible`() throws {
        let legacyJSON = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "codex",
                    "quotaWarnings": {
                        "session": { "thresholds": [10] },
                        "weekly": { "enabled": false }
                    }
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(legacyJSON.utf8))
        let quotaWarnings = try #require(decoded.providerConfig(for: .codex)?.quotaWarnings)

        #expect(quotaWarnings.isEnabled(for: .session, global: false) == true)
        #expect(quotaWarnings.isEnabled(for: .weekly, global: true) == false)
        #expect(quotaWarnings.hasOverride(for: .session) == true)
        #expect(quotaWarnings.hasOverride(for: .weekly) == true)
    }

    @Test
    func `provider config encodes live system active source with expected schema`() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .codex,
                    codexActiveSource: .liveSystem),
            ])

        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let providers = try #require(object?["providers"] as? [[String: Any]])
        let provider = try #require(providers.first(where: { $0["id"] as? String == "codex" }))
        let activeSource = try #require(provider["codexActiveSource"] as? [String: Any])

        #expect(activeSource.count == 1)
        #expect(activeSource["kind"] as? String == "liveSystem")
        #expect(activeSource["accountID"] == nil)
    }

    @Test
    func `provider config encodes managed account active source with expected schema`() throws {
        let accountID = UUID()
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .codex,
                    codexActiveSource: .managedAccount(id: accountID)),
            ])

        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let providers = try #require(object?["providers"] as? [[String: Any]])
        let provider = try #require(providers.first(where: { $0["id"] as? String == "codex" }))
        let activeSource = try #require(provider["codexActiveSource"] as? [String: Any])

        #expect(activeSource.count == 2)
        #expect(activeSource["kind"] as? String == "managedAccount")
        #expect((activeSource["accountID"] as? String) == accountID.uuidString)
    }

    @Test
    func `provider config round trips live system active source`() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .codex,
                    codexActiveSource: .liveSystem),
            ])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.providerConfig(for: .codex)?.codexActiveSource == .liveSystem)
    }

    @Test
    func `provider config round trips managed account active source`() throws {
        let accountID = UUID()
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .codex,
                    codexActiveSource: .managedAccount(id: accountID)),
            ])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.providerConfig(for: .codex)?.codexActiveSource == .managedAccount(id: accountID))
    }
}
