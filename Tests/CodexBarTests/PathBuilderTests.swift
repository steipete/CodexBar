import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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
    func `shell runner drains noisy stdout and stderr`() throws {
        let script = """
        i=0
        while [ "$i" -lt 4000 ]; do
          printf 'out-%04d\\n' "$i"
          printf 'err-%04d\\n' "$i" >&2
          i=$((i + 1))
        done
        printf '__CODEXBAR_DONE__\\n'
        """
        let data = try #require(ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", script],
            timeout: 4.0))
        let output = try #require(String(data: data, encoding: .utf8))

        #expect(output.contains("out-3999"))
        #expect(output.contains("__CODEXBAR_DONE__"))
    }

    @Test
    func `shell runner terminates background children after normal exit`() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-shell-runner-\(UUID().uuidString)")
            .path
        let escapedMarker = Self.shellSingleQuoted(marker)
        let script = """
        (
          trap '' TERM
          touch \(escapedMarker)
          while :; do sleep 1; done
        ) &
        printf '%s\\n' "$!"
        """
        let data = try #require(ShellCommandLocator.test_runShellCommand(
            shell: "/bin/sh",
            arguments: ["-c", script],
            timeout: 2.0))
        let pidText = try #require(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let pid = try #require(pid_t(pidText))

        defer {
            kill(pid, SIGKILL)
            try? FileManager.default.removeItem(atPath: marker)
        }

        let deadline = Date().addingTimeInterval(2.0)
        while kill(pid, 0) == 0, Date() < deadline {
            usleep(50000 as useconds_t)
        }

        #expect(kill(pid, 0) != 0)
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
    func `skips blocked codex path and falls back to signed app binary`() {
        let blockedPath = "/usr/local/bin/codex"
        let appPath = "/Applications/Codex.app/Contents/Resources/codex"
        let fm = MockFileManager(executables: [blockedPath, appPath])
        var checked: [String] = []

        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["PATH": "/usr/local/bin"],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            launchCandidateFilter: { path, _ in
                checked.append(path)
                return path != blockedPath
            },
            fileManager: fm,
            home: "/Users/test")

        #expect(resolved == appPath)
        #expect(checked == [blockedPath, appPath])
    }

    @Test
    func `explicit codex override bypasses launch candidate fallback`() {
        let overridePath = "/custom/bin/codex"
        let appPath = "/Applications/Codex.app/Contents/Resources/codex"
        let fm = MockFileManager(executables: [overridePath, appPath])
        var checked: [String] = []

        let resolved = BinaryLocator.resolveCodexBinary(
            env: ["CODEX_CLI_PATH": overridePath],
            loginPATH: nil,
            launchCandidateFilter: { path, _ in
                checked.append(path)
                return false
            },
            fileManager: fm,
            home: "/Users/test")

        #expect(resolved == overridePath)
        #expect(checked.isEmpty)
    }

    @Test
    func `Codex CLI strategy availability uses filtered binary resolution`() {
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let unavailable = CodexCLIUsageStrategy.resolvedBinary(
            env: ["PATH": "/missing/bin", "SHELL": "/bin/sh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: MockFileManager(executables: []),
            home: "/home/test")
        #expect(unavailable == nil)

        let available = CodexCLIUsageStrategy.resolvedBinary(
            env: ["PATH": "/tools/bin", "SHELL": "/bin/sh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: MockFileManager(executables: ["/tools/bin/codex"]),
            home: "/home/test")
        #expect(available == "/tools/bin/codex")
    }

    #if os(macOS)
    @Test
    func `Codex launch preflight allows quarantined notarized native binary`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/Applications/Codex.app/Contents/Resources/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { _ in "accepted\nsource=Notarized Developer ID" },
            isMachOExecutable: { _ in true })

        #expect(allowed)
    }

    @Test
    func `Codex launch preflight blocks malware attribute before assessment`() {
        var assessed = false
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/Applications/Codex.app/Contents/Resources/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.malware" },
            spctlAssessment: { _ in
                assessed = true
                return "accepted\nsource=Notarized Developer ID"
            },
            isMachOExecutable: { _ in true })

        #expect(!allowed)
        #expect(!assessed)
    }

    @Test
    func `Codex launch preflight blocks quarantined script without native assessment`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/opt/homebrew/bin/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { _ in nil },
            isMachOExecutable: { _ in false })

        #expect(!allowed)
    }

    @Test
    func `Codex launch preflight blocks revoked assessment`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/Applications/Codex.app/Contents/Resources/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, _ in false },
            spctlAssessment: { _ in "rejected\nCSSMERR_TP_CERT_REVOKED" },
            isMachOExecutable: { _ in true })

        #expect(!allowed)
    }

    @Test
    func `Codex launch preflight blocks generic Gatekeeper rejection`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/opt/homebrew/bin/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, _ in false },
            spctlAssessment: { _ in "rejected\nsource=no usable signature" },
            isMachOExecutable: { _ in true })

        #expect(!allowed)
    }

    @Test
    func `Codex launch preflight allows valid signed command line binary assessment`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/opt/homebrew/bin/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { path in "\(path): rejected (the code is valid but does not seem to be an app)" },
            isMachOExecutable: { _ in true })

        #expect(allowed)
    }

    @Test
    func `Codex launch preflight blocks revoked assessment even with non app rejection text`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/opt/homebrew/bin/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { _ in
                """
                rejected (the code is valid but does not seem to be an app)
                CSSMERR_TP_CERT_REVOKED
                """
            },
            isMachOExecutable: { _ in true })

        #expect(!allowed)
    }

    @Test
    func `Codex launch preflight ignores benign text in path when verdict is generic rejection`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/tmp/code is valid but does not seem to be an app/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { path in "\(path): rejected\nsource=no usable signature" },
            isMachOExecutable: { _ in true })

        #expect(!allowed)
    }

    @Test
    func `Codex launch preflight ignores benign text before verdict separator`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/tmp/x: code is valid but does not seem to be an app/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { path in "\(path): rejected\nsource=no usable signature" },
            isMachOExecutable: { _ in true })

        #expect(!allowed)
    }

    @Test
    func `Codex launch preflight ignores blocked words in accepted path and source fields`() {
        let allowed = CodexLaunchPreflight.isLaunchCandidateAllowed(
            path: "/tmp/rejected/quarantine/codex",
            fileManager: MockFileManager(executables: []),
            hasExtendedAttribute: { _, name in name == "com.apple.quarantine" },
            spctlAssessment: { path in
                """
                \(path): accepted
                source=revoked quarantine marker
                origin=malware test fixture
                """
            },
            isMachOExecutable: { _ in true })

        #expect(allowed)
    }
    #endif

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
    func `prefers well-known paths over interactive shell lookup`() {
        let shellPath = "/custom/bin/claude"
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/claude"
        let fm = MockFileManager(executables: [shellPath, cmuxPath])
        var shellLookupCalled = false
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            shellLookupCalled = true
            return shellPath
        }

        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            fileManager: fm,
            home: "/Users/test")
        #expect(!shellLookupCalled)
        #expect(resolved == cmuxPath)
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

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
