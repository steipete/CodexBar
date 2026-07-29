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
