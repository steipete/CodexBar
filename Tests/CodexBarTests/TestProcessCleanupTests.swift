import Foundation
import Testing

struct TestProcessCleanupTests {
    @Test
    func `cleanup pattern matches only CodexBar test stub app servers`() throws {
        let regex = try NSRegularExpression(pattern: TestProcessCleanup.codexTestStubCommandRegex)
        let testStubCommands = [
            "/usr/bin/python3 -S /tmp/codex-stub-01234567-89AB-CDEF-0123-456789ABCDEF app-server",
            "/bin/sh /tmp/codex-fallback-stub-01234567-89AB-CDEF-0123-456789ABCDEF app-server",
            "/bin/sh /tmp/codex-plan-only-stub-01234567-89AB-CDEF-0123-456789ABCDEF app-server",
            "/bin/sh /tmp/codex-credits-only-stub-01234567-89AB-CDEF-0123-456789ABCDEF app-server",
            "/bin/sh /tmp/codex-hung-stub-01234567-89AB-CDEF-0123-456789ABCDEF app-server",
        ]
        let userCommands = [
            "/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://",
            "/opt/homebrew/bin/codex app-server",
            "node /Users/test/node_modules/.bin/codex app-server --listen stdio://",
            "/tmp/codex-stub-cache app-server",
            "/tmp/codex-stub-01234567-89AB-CDEF-0123 app-server",
            "/tmp/codex-stub-01234567-89AB-CDEF-0123-456789ABCDEF app-server-helper",
        ]

        for command in testStubCommands {
            #expect(Self.matches(regex, command))
        }
        for command in userCommands {
            #expect(!Self.matches(regex, command))
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ command: String) -> Bool {
        regex.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)) != nil
    }
}
