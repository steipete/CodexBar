import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityBinaryLocatorTests {
    @Test(arguments: ["/nonexistent-agy-guard", "", "   ", "agy"])
    func `unusable env override fails without ambient fallback`(override: String) {
        // The ambient binary exists on every lookup channel (login PATH, env
        // PATH, well-known install paths); a set-but-unusable override must
        // still fail resolution so a background fetch can never spawn it.
        let ambient = "/opt/homebrew/bin/agy"
        let fileManager = AntigravityLocatorMockFileManager(executables: [
            ambient,
            "/Applications/Gemini.app/Contents/Helpers/agy",
        ])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            Issue.record("An unusable override must not run shell lookup")
            return ambient
        }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in
            Issue.record("An unusable override must not run alias lookup")
            return ambient
        }

        let resolved = BinaryLocator.resolveAntigravityBinary(
            env: ["ANTIGRAVITY_CLI_PATH": override, "PATH": "/opt/homebrew/bin"],
            loginPATH: ["/opt/homebrew/bin"],
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == nil)
    }

    @Test
    func `usable env override is used without other lookups`() {
        let overridePath = "/custom/bin/agy"
        let fileManager = AntigravityLocatorMockFileManager(executables: [overridePath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in
            Issue.record("A usable override must not run shell lookup")
            return nil
        }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in
            Issue.record("A usable override must not run alias lookup")
            return nil
        }

        let resolved = BinaryLocator.resolveAntigravityBinary(
            env: ["ANTIGRAVITY_CLI_PATH": overridePath],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == overridePath)
    }

    @Test
    func `without override well known paths still resolve`() {
        let homebrewPath = "/opt/homebrew/bin/agy"
        let fileManager = AntigravityLocatorMockFileManager(executables: [homebrewPath])
        let commandV: (String, String?, TimeInterval, FileManager) -> String? = { _, _, _, _ in nil }
        let aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = { _, _, _, _, _ in nil }

        let resolved = BinaryLocator.resolveAntigravityBinary(
            env: ["SHELL": "/bin/zsh"],
            loginPATH: nil,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: "/home/test")

        #expect(resolved == homebrewPath)
    }

    @Test(arguments: ["/bin/agy", nil] as [String?])
    func `minimal fallback preserves a hit or no executable`(expected: String?) {
        let resolved = BinaryLocator.resolveAntigravityBinary(
            env: [:],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            fileManager: AntigravityLocatorMockFileManager(executables: Set([expected].compactMap(\.self))),
            home: "/home/test")

        #expect(resolved == expected)
    }

    @Test(arguments: ["/Applications", "/home/test/Applications"])
    func `Gemini bundled helper is the last fallback`(applications: String) {
        let bundled = "\(applications)/Gemini.app/Contents/Helpers/agy"
        let installed = "/custom/bin/agy"
        let fileManager = AntigravityLocatorMockFileManager(executables: [bundled, installed])
        let fallback = BinaryLocator.resolveAntigravityBinary(
            env: [:],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            fileManager: fileManager,
            home: "/home/test")
        #expect(fallback == bundled)

        let shellCLI = BinaryLocator.resolveAntigravityBinary(
            env: [:],
            loginPATH: nil,
            commandV: { _, _, _, _ in installed },
            aliasResolver: { _, _, _, _, _ in nil },
            fileManager: fileManager,
            home: "/home/test")
        #expect(shellCLI == installed)
    }

    @Test
    func `other providers retain unusable override fallback`() {
        let ambient = "/ambient/bin/claude"
        let resolved = BinaryLocator.resolveClaudeBinary(
            env: ["CLAUDE_CLI_PATH": "/missing/claude", "PATH": "/ambient/bin"],
            loginPATH: nil,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            fileManager: AntigravityLocatorMockFileManager(executables: [ambient]),
            home: "/home/test")

        #expect(resolved == ambient)
    }
}

private final class AntigravityLocatorMockFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        self.executables.contains(path)
    }
}
