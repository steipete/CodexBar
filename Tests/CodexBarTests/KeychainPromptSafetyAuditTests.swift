import Foundation
import Testing

struct KeychainPromptSafetyAuditTests {
    @Test
    func `agent instructions forbid keychain prompt validation`() throws {
        let agents = try Self.readRepoFile("AGENTS.md")

        #expect(agents.contains("Never run tests/checks or ad-hoc validation that can display macOS Keychain prompts"))
        #expect(agents.contains("use parser tests, stubs, test stores, or `KeychainNoUIQuery`"))
    }

    @Test
    func `default test runner explicitly suppresses real keychain access`() throws {
        let script = try Self.readRepoFile("Scripts/test.sh")

        #expect(script.contains("CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"))
        #expect(script.contains("export CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1"))
    }

    @Test
    func `live TTY integration tests are opt in`() throws {
        let ttyTests = try Self.readRepoFile("Tests/CodexBarTests/TTYIntegrationTests.swift")

        #expect(ttyTests.contains("LIVE_CODEX_TTY"))
        #expect(ttyTests.contains("LIVE_CLAUDE_TTY"))
        #expect(ttyTests.contains("guard ProcessInfo.processInfo.environment[\"LIVE_CODEX_TTY\"] == \"1\""))
        #expect(ttyTests.contains("guard ProcessInfo.processInfo.environment[\"LIVE_CLAUDE_TTY\"] == \"1\""))
    }

    @Test
    func `interactive keychain prompt test paths use test doubles`() throws {
        let promptLiteral = "allowKeychainPrompt: true"
        let testFiles = try Self.swiftTestFiles(excludingSelf: true)
        let promptCallSites = try testFiles.flatMap { file in
            try Self.lines(in: file)
                .enumerated()
                .filter { _, line in line.contains(promptLiteral) }
                .map { lineNumber, _ in PromptCallSite(file: file, lineNumber: lineNumber + 1) }
        }

        #expect(promptCallSites.isEmpty == false)
        for callSite in promptCallSites {
            let lines = try Self.lines(in: callSite.file)
            let usesScopedKeychainDouble = Self.hasOpenKeychainTestDouble(lines: lines, before: callSite.lineNumber)
            let failureMessage = "\(callSite.file.path):\(callSite.lineNumber) has \(promptLiteral) "
                + "without an enclosing keychain test double"
            #expect(usesScopedKeychainDouble, "\(failureMessage)")
        }
    }

    @Test
    func `claude availability tests with keychain enabled use test doubles`() throws {
        let file = Self.repoRoot().appendingPathComponent(
            "Tests/CodexBarTests/ClaudeOAuthFetchStrategyAvailabilityTests.swift")
        let lines = try Self.lines(in: file)
        let callSites = lines.enumerated().compactMap { lineNumber, line -> PromptCallSite? in
            guard line.contains("strategy.isAvailable(context)") else { return nil }
            let oneBasedLineNumber = lineNumber + 1
            guard Self.hasOpenScope(
                containing: "KeychainAccessGate.withTaskOverrideForTesting(false)",
                lines: lines,
                before: oneBasedLineNumber)
            else {
                return nil
            }
            return PromptCallSite(file: file, lineNumber: oneBasedLineNumber)
        }

        #expect(callSites.isEmpty == false)
        for callSite in callSites {
            let failureMessage = "\(callSite.file.path):\(callSite.lineNumber) calls strategy.isAvailable(context) "
                + "with test keychain access enabled and incomplete scoped keychain isolation"
            #expect(
                Self.hasOpenAvailabilityKeychainIsolation(lines: lines, before: callSite.lineNumber),
                "\(failureMessage)")
        }
    }

    @Test
    func `availability audit rejects a Claude-only keychain override`() {
        let lines: [Substring] = [
            "KeychainAccessGate.withTaskOverrideForTesting(false) {",
            "ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {",
            "strategy.isAvailable(context)",
            "}",
            "}",
        ]

        #expect(Self.hasOpenAvailabilityKeychainIsolation(lines: lines, before: 3) == false)
    }

    @Test
    func `availability audit accepts combined cache and Claude keychain doubles`() {
        let lines: [Substring] = [
            "KeychainAccessGate.withTaskOverrideForTesting(false) {",
            "self.withAvailabilityKeychainDoubles {",
            "strategy.isAvailable(context)",
            "}",
            "}",
        ]

        #expect(Self.hasOpenAvailabilityKeychainIsolation(lines: lines, before: 3))
    }

    @Test
    func `prompt audit accepts interactive Claude keychain read double`() {
        let lines: [Substring] = [
            "ClaudeOAuthCredentialsStore.withInteractiveClaudeKeychainReadOverridesForTesting(",
            "    operation: {",
            "        allowKeychainPrompt: true",
            "    })",
        ]

        #expect(Self.hasOpenKeychainTestDouble(lines: lines, before: 3))
    }

    @Test
    func `tests do not call Security item APIs except no UI query coverage`() throws {
        let securityItemCalls = ["SecItemCopyMatching", "SecItemUpdate", "SecItemAdd", "SecItemDelete"]
        let offenders = try Self.swiftTestFiles().filter { file in
            let text = try Self.readFile(file)
            return securityItemCalls.contains(where: text.contains)
                && !file.path.hasSuffix("Tests/CodexBarTests/KeychainNoUIQueryTests.swift")
                && !file.path.hasSuffix("Tests/CodexBarTests/KeychainPromptSafetyAuditTests.swift")
        }

        #expect(offenders.isEmpty, "Unexpected direct Security item access in tests: \(offenders.map(\.path))")
    }

    @Test
    func `production source routes Security item APIs through the test safety gateway`() throws {
        let securityItemCalls = ["SecItemCopyMatching", "SecItemUpdate", "SecItemAdd", "SecItemDelete"]
        let offenders = try Self.swiftFiles(
            under: Self.repoRoot().appendingPathComponent("Sources", isDirectory: true))
            .filter { file in
                guard !file.path.hasSuffix("Sources/CodexBarCore/KeychainSecurity.swift") else { return false }
                let text = try Self.readFile(file)
                return securityItemCalls.contains(where: text.contains)
            }

        #expect(offenders.isEmpty, "Security item access bypasses KeychainSecurity: \(offenders.map(\.path))")
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func readRepoFile(_ relativePath: String) throws -> String {
        try self.readFile(self.repoRoot().appendingPathComponent(relativePath))
    }

    private static func readFile(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func lines(in url: URL) throws -> [Substring] {
        try self.readFile(url).split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func swiftTestFiles(excludingSelf: Bool = false) throws -> [URL] {
        let testsRoot = self.repoRoot().appendingPathComponent("Tests/CodexBarTests", isDirectory: true)
        return try self.swiftFiles(under: testsRoot).filter { file in
            !(excludingSelf && file.path.hasSuffix("Tests/CodexBarTests/KeychainPromptSafetyAuditTests.swift"))
        }
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(file)
            }
        }
        return files
    }

    private static func hasOpenKeychainTestDouble(lines: [Substring], before oneBasedLineNumber: Int) -> Bool {
        let helperNames = [
            "withClaudeKeychainOverridesForTesting",
            "withInteractiveClaudeKeychainReadOverridesForTesting",
            "withKeychainAccessOverrideForTesting(true)",
            "withSecurityCLIReadOverrideForTesting",
            "KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting",
        ]
        return helperNames.contains { helperName in
            self.hasOpenScope(containing: helperName, lines: lines, before: oneBasedLineNumber)
        }
    }

    private static func hasOpenAvailabilityKeychainIsolation(
        lines: [Substring],
        before oneBasedLineNumber: Int) -> Bool
    {
        if self.hasOpenScope(
            containing: "withAvailabilityKeychainDoubles",
            lines: lines,
            before: oneBasedLineNumber)
        {
            return true
        }

        let bypassesCacheKeychain = self.hasOpenScope(
            containing: "nonInteractiveCredentialRecordOverride",
            lines: lines,
            before: oneBasedLineNumber)
        return bypassesCacheKeychain
            && self.hasOpenKeychainTestDouble(lines: lines, before: oneBasedLineNumber)
    }

    private static func hasOpenScope(
        containing needle: String,
        lines: [Substring],
        before oneBasedLineNumber: Int) -> Bool
    {
        let targetIndex = oneBasedLineNumber - 1
        let lineRange = lines.indices.prefix(through: targetIndex)
        return lineRange.contains { index in
            lines[index].contains(needle)
                && self.hasOpenBraceScope(lines: lines, from: index, through: targetIndex)
        }
    }

    private static func hasOpenBraceScope(lines: [Substring], from startIndex: Int, through endIndex: Int) -> Bool {
        var balance = 0
        var sawOpeningBrace = false
        for index in startIndex...endIndex {
            let line = lines[index]
            for character in line {
                switch character {
                case "{":
                    balance += 1
                    sawOpeningBrace = true
                case "}":
                    balance -= 1
                default:
                    continue
                }
            }
            if index < endIndex, sawOpeningBrace, balance <= 0 {
                return false
            }
        }
        return sawOpeningBrace && balance > 0
    }

    private struct PromptCallSite {
        let file: URL
        let lineNumber: Int
    }
}
