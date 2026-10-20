import CodexBarCore
import Foundation
import Testing

struct CodexBarConfigHooksTests {
    @Test
    func `hooks survive config round trip`() throws {
        let hooks = HooksConfig(
            enabled: true,
            events: [
                HookRule(
                    id: "quota-low",
                    event: .quotaLow,
                    provider: "codex",
                    threshold: 0.9,
                    executable: "/usr/bin/true",
                    timeoutSeconds: 30),
            ])
        let config = CodexBarConfig(
            providers: [ProviderConfig(id: .codex, enabled: true)],
            hooks: hooks)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.hooks == hooks)
    }
}

struct CodexBarConfigShareUsageTests {
    private static let legacyJSON = Data(#"{"version":1,"providers":[{"id":"codex","enabled":true}]}"#.utf8)

    @Test
    func `sharing is opt in and legacy configs omit the flag on round trip`() throws {
        var config = try CodexBarConfig.decode(from: Self.legacyJSON)
        #expect(!config.shareUsageWithCLI)
        #expect(config.providers.first?.enabled == true)
        for enabled in [false, true, false] {
            config.shareUsageWithCLI = enabled
            let data = try config.encodedData()
            #expect(try #require(String(data: data, encoding: .utf8)).contains("shareUsageWithCLI") == enabled)
            #expect(try CodexBarConfig.decode(from: data).shareUsageWithCLI == enabled)
        }
    }
}
