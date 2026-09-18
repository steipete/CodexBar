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
        let fileManager = AntigravityLocatorMockFileManager(executables: [ambient])
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

    @Test
    func `broken override marks the CLI strategy unavailable`() async {
        // isAvailable uses the default login-PATH cache and file manager, but a
        // set override short-circuits both: resolution fails before any ambient
        // lookup, so no real agy can be spawned from a background fetch.
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["ANTIGRAVITY_CLI_PATH": "/nonexistent-agy-guard"],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubAntigravityLocatorClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: nil,
            persistsCLISessions: false)

        let available = await AntigravityCLIHTTPSFetchStrategy().isAvailable(context)
        #expect(!available)
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

private struct StubAntigravityLocatorClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ClaudeUsageError.parseFailed("stub")
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}
