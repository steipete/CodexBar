import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginIconProviderTests {
    @Test
    func `pre-icon snapshots and version one plugin settings retain their data`() throws {
        let legacy = Data(#"""
        {"primary":{"usedPercent":25,"windowMinutes":10080},"secondary":null,"tertiary":null,
         "updatedAt":0,"identity":{"providerID":"proxy-meter","accountEmail":"fixture@example.test"},
         "dataConfidence":"percentOnly"}
        """#.utf8)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: legacy)
        #expect(snapshot.iconProvider == nil)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.windowMinutes == 10080)
        #expect(snapshot.identity?.providerID?.rawValue == "proxy-meter")
        #expect(snapshot.identity?.accountEmail == "fixture@example.test")
        #expect(snapshot.dataConfidence == .percentOnly)
        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["iconProvider"] == nil)
        let config = Data(#"""
        {"version":1,"providers":[{"id":"proxy-meter","enabled":true,
         "pluginSettings":{"MENUBAR_PROVIDER":"claude"},"pluginSecrets":{"TOKEN":"fixture-secret"}}]}
        """#.utf8)
        let decoded = try CodexBarConfig.decode(from: config)
        let original = try #require(JSONSerialization.jsonObject(with: config) as? NSDictionary)
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary)
        #expect(original == roundTrip)
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `host advertises built-in icon support without changing plugin identity`(
        engine: ProviderPluginEngineKind) async throws
    {
        for provider in [UsageProvider.claude, .codex, .antigravity, .zai] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
            if (ctx.env.supportsIconProvider !== true) throw new Error('icon support missing');
            return { iconProvider: '\(provider.rawValue)', primary: { usedPercent: 25 },
              identity: { accountEmail: 'fixture@example.test' } };
            """)
            let snapshot = try await runtime.fetchUsage()
            #expect(snapshot.iconProvider == provider)
            #expect(snapshot.primary?.usedPercent == 25)
            #expect(snapshot.identity?.providerID?.rawValue == "neuralwatt")
            let copy = snapshot.withDataConfidence(.percentOnly).with(details: [])
            #expect(copy.iconProvider == provider)
            let encoded = try JSONEncoder().encode(copy)
            let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
            #expect(decoded.iconProvider == provider)
            #expect(decoded.identity?.providerID == copy.identity?.providerID)
            #expect(decoded.identity?.accountEmail == copy.identity?.accountEmail)
            #expect(decoded.primary?.usedPercent == 25)
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `absent and null icon providers keep the legacy snapshot schema`(
        engine: ProviderPluginEngineKind) async throws
    {
        for field in ["", "iconProvider: null,"] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
            return { \(field) primary: { usedPercent: 25 } };
            """)
            let snapshot = try await runtime.fetchUsage()
            #expect(snapshot.iconProvider == nil)
            let json = try #require(JSONSerialization
                .jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            #expect(json["iconProvider"] == nil)
            #expect(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
                .iconProvider == nil)
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `icon providers reject paths URLs unknown IDs and nonstrings`(engine: ProviderPluginEngineKind) async throws {
        for value in [
            "'unknown-provider'",
            "'CLAUDE'",
            "'https://example.com/icon.svg'",
            "'/tmp/icon.svg'",
            "''",
            "42",
            "true",
            "{}",
            "[]",
        ] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
            return { iconProvider: \(value), primary: { usedPercent: 25 } };
            """)
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `an icon is not a quota measurement or an identity`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: "return { iconProvider: 'claude' };")
        await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        let empty = try ProviderPluginTransportTests.runtime(
            engine,
            body: "return { empty: true, iconProvider: 'claude' };")
        let snapshot = try await empty.fetchUsage()
        #expect(snapshot.iconProvider == .claude)
        #expect(snapshot.primary == nil)
        #expect(snapshot.extraRateWindows == nil)
    }
}
