import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PathBuilderTests {
    @Test
    func `merges login shell path when available`() {
        let seeded = PathBuilder.effectivePATH(
            purposes: [.rpc],
            env: ["PATH": "/custom/bin:/usr/bin"],
            loginPATH: ["/login/bin", "/login/alt"])
        #expect(seeded == "/login/bin:/login/alt:/custom/bin:/usr/bin")
    }

    @Test
    func `falls back to existing path when no login path`() {
        let seeded = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: ["PATH": "/custom/bin:/usr/bin"],
            loginPATH: nil)
        #expect(seeded == "/custom/bin:/usr/bin")
    }

    @Test
    func `uses fallback when no path available`() {
        let seeded = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: [:],
            loginPATH: nil)
        #expect(seeded == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test
    func `debug snapshot async matches sync`() async {
        let env = [
            "CODEX_CLI_PATH": "/usr/bin/true",
            "CLAUDE_CLI_PATH": "/usr/bin/true",
            "GEMINI_CLI_PATH": "/usr/bin/true",
            "PATH": "/usr/bin:/bin",
        ]
        let sync = PathBuilder.debugSnapshot(purposes: [.rpc], env: env, home: "/tmp")
        let async = await PathBuilder.debugSnapshotAsync(purposes: [.rpc], env: env, home: "/tmp")
        #expect(async == sync)
    }

    @Test
    func `resolves codex from env override`() {
        let overridePath = "/custom/bin/codex"
        let fm = MockFileManager(executables: [overridePath])

        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["CODEX_CLI_PATH": overridePath],
            loginPATH: nil,
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == overridePath)
    }

    @Test
    func `resolves codex from login path`() {
        let fm = MockFileManager(executables: ["/login/bin/codex"])
        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["PATH": "/env/bin"],
            loginPATH: ["/login/bin"],
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/login/bin/codex")
    }

    @Test
    func `resolves codex from env path`() {
        let fm = MockFileManager(executables: ["/env/bin/codex"])
        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["PATH": "/env/bin:/usr/bin"],
            loginPATH: nil,
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/env/bin/codex")
    }

    @Test
    func `resolves codex from interactive shell`() {
        let fm = MockFileManager(executables: ["/shell/bin/codex"])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { tool, shell, timeout, fileManager in
            #expect(tool == "codex")
            #expect(shell == "/bin/zsh")
            #expect(timeout == 2.0)
            _ = fileManager
            return "/shell/bin/codex"
        }

        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/shell/bin/codex")
    }

    @Test
    func `resolves claude from interactive shell`() {
        let fm = MockFileManager(executables: ["/shell/bin/claude"])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { tool, shell, timeout, fileManager in
            #expect(tool == "claude")
            #expect(shell == "/bin/zsh")
            #expect(timeout == 2.0)
            _ = fileManager
            return "/shell/bin/claude"
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/shell/bin/claude")
    }

    @Test
    func `resolves gemini from interactive shell`() {
        let fm = MockFileManager(executables: ["/shell/bin/gemini"])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { tool, shell, timeout, fileManager in
            #expect(tool == "gemini")
            #expect(shell == "/bin/zsh")
            #expect(timeout == 2.0)
            _ = fileManager
            return "/shell/bin/gemini"
        }

        let resolved = BinaryLocator.resolveGeminiBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/shell/bin/gemini")
    }

    @Test
    func `resolves claude from login path`() {
        let fm = MockFileManager(executables: ["/login/bin/claude"])
        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["PATH": "/env/bin"],
            loginPATH: ["/login/bin"],
            fileManager: fm,
            home: "/home/test")
        #expect(resolved == "/login/bin/claude")
    }

    @Test
    func `resolves claude from alias when other lookups fail`() {
        let aliasPath = "/home/test/.claude/local/bin/claude"
        let fm = MockFileManager(executables: [aliasPath])
        var aliasCalled = false
        let aliasResolver: (String, String?, TimeInterval, FileManager, String)
            -> String? = { tool, shell, timeout, _, home in
                aliasCalled = true
                #expect(tool == "claude")
                #expect(shell == "/bin/zsh")
                #expect(timeout == 2.0)
                #expect(home == "/home/test")
                return aliasPath
            }
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            nil
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/home/test")

        #expect(aliasCalled)
        #expect(resolved == aliasPath)
    }

    @Test
    func `resolves codex from alias when other lookups fail`() {
        let aliasPath = "/home/test/.codex/bin/codex"
        let fm = MockFileManager(executables: [aliasPath])
        var aliasCalled = false
        let aliasResolver: (String, String?, TimeInterval, FileManager, String)
            -> String? = { tool, shell, timeout, _, home in
                aliasCalled = true
                #expect(tool == "codex")
                #expect(shell == "/bin/zsh")
                #expect(timeout == 2.0)
                #expect(home == "/home/test")
                return aliasPath
            }
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            nil
        }

        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/home/test")

        #expect(aliasCalled)
        #expect(resolved == aliasPath)
    }

    @Test
    func `resolves claude from well-known cmux path when shell lookups fail`() {
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [cmuxPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == cmuxPath)
    }

    @Test
    func `resolves claude from well-known home dir path`() {
        let homePath = "/Users/test/.claude/bin/claude"
        let fm = MockFileManager(executables: [homePath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == homePath)
    }

    @Test
    func `resolves claude from native installer path`() {
        let nativePath = "/Users/test/.local/bin/claude"
        let fm = MockFileManager(executables: [nativePath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == nativePath)
    }

    @Test
    func `prefers migrated local claude path over legacy home dir path`() {
        let migratedPath = "/Users/test/.claude/local/claude"
        let legacyPath = "/Users/test/.claude/bin/claude"
        let fm = MockFileManager(executables: [migratedPath, legacyPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == migratedPath)
    }

    @Test
    func `prefers user managed well-known path over cmux path`() {
        let homePath = "/Users/test/.claude/bin/claude"
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [homePath, cmuxPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == homePath)
    }

    @Test
    func `prefers homebrew arm path over usr local fallback`() {
        let fm = MockFileManager(executables: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == "/opt/homebrew/bin/claude")
    }

    @Test
    func `prefers shell PATH over well-known paths`() {
        let shellPath = "/custom/bin/claude"
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [shellPath, cmuxPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in shellPath }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/Users/test")
        #expect(resolved == shellPath)
    }

    @Test
    func `skips alias when command V resolves`() {
        let path = "/shell/bin/claude"
        let fm = MockFileManager(executables: [path])
        var aliasCalled = false
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in
            aliasCalled = true
            return "/alias/claude"
        }
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            path
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fm,
            home: "/home/test")

        #expect(!aliasCalled)
        #expect(resolved == path)
    }
}

private final class MockFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        self.executables.contains(path)
    }
}
