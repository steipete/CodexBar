import Testing
@testable import CodexBarCore

struct CodexExecutableResolverTests {
    @Test
    func `explicit override skips login path capture`() {
        let resolved = resolveCodexExecutableForRPC(
            environment: ["CODEX_CLI_PATH": "/usr/bin/true"],
            executable: "codex",
            captureLoginPATH: {
                Issue.record("Explicit Codex override should not capture a login-shell PATH")
                return nil
            })

        #expect(resolved == "/usr/bin/true")
    }
}
