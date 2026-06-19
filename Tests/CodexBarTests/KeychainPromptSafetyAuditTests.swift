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
    func `tests do not call SecItemCopyMatching except no UI query coverage`() throws {
        let offenders = try Self.swiftTestFiles().filter { file in
            let text = try Self.readFile(file)
            return text.contains("SecItemCopyMatching")
                && !file.path.hasSuffix("Tests/CodexBarTests/KeychainNoUIQueryTests.swift")
                && !file.path.hasSuffix("Tests/CodexBarTests/KeychainPromptSafetyAuditTests.swift")
        }

        #expect(offenders.isEmpty, "Unexpected direct SecItemCopyMatching in tests: \(offenders.map(\.path))")
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
        guard let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                if excludingSelf, file.path.hasSuffix("Tests/CodexBarTests/KeychainPromptSafetyAuditTests.swift") {
                    continue
                }
                files.append(file)
            }
        }
        return files
    }

    private static func hasOpenKeychainTestDouble(lines: [Substring], before oneBasedLineNumber: Int) -> Bool {
        let helperNames = [
            "withClaudeKeychainOverridesForTesting",
            "withSecurityCLIReadOverrideForTesting",
            "KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting",
        ]
        let targetIndex = oneBasedLineNumber - 1
        let lineRange = lines.indices.prefix(through: targetIndex)
        return lineRange.contains { index in
            helperNames.contains { lines[index].contains($0) }
                && self.hasOpenBraceScope(lines: lines, from: index, through: targetIndex)
        }
    }

    private static func hasOpenBraceScope(lines: [Substring], from startIndex: Int, through endIndex: Int) -> Bool {
        var balance = 0
        var sawOpeningBrace = false
        for line in lines[startIndex...endIndex] {
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
        }
        return sawOpeningBrace && balance > 0
    }

    private struct PromptCallSite {
        let file: URL
        let lineNumber: Int
    }
}
