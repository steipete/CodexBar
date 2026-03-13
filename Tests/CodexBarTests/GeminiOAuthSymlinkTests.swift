@testable import CodexBarCore
import Foundation
import Testing

/// Regression tests for multi-level symlink resolution when locating
/// Gemini CLI's oauth2.js file.
///
/// See: https://github.com/steipete/CodexBar/pull/497
///
/// On some setups (e.g. Apple Silicon with `/usr/local/bin/gemini` →
/// `/opt/homebrew/bin/gemini` → `../Cellar/…/bin/gemini` → …), the
/// previous single-level `destinationOfSymbolicLink` call resolved too
/// shallowly, producing a wrong base path and silently failing to find
/// the OAuth credentials file.
@Suite
struct GeminiOAuthSymlinkTests {
    /// Sample oauth2.js content used by all tests.
    private static let sampleOAuth2JS = """
        const OAUTH_CLIENT_ID = 'test-client-id.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'test-client-secret';
        """

    // MARK: - Helpers

    /// Build a temporary directory tree that mimics a Homebrew Cellar layout
    /// and return the path to the top-level "entry" symlink.
    ///
    /// Layout created:
    /// ```
    ///   <root>/
    ///     usr/local/bin/gemini  → <root>/opt/homebrew/bin/gemini       (level 0 — optional)
    ///     opt/homebrew/bin/gemini → ../Cellar/gemini-cli/0.32.1/bin/gemini  (level 1)
    ///     opt/homebrew/Cellar/gemini-cli/0.32.1/
    ///       bin/gemini → ../libexec/bin/gemini                         (level 2)
    ///       libexec/bin/gemini  (regular file — final target)
    ///       libexec/lib/node_modules/@google/gemini-cli/
    ///         node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js
    /// ```
    private static func makeBrewLayout(
        root: URL,
        includeExtraSymlink: Bool) throws -> String
    {
        let fm = FileManager.default

        // Cellar paths
        let cellarBase = root.appendingPathComponent(
            "opt/homebrew/Cellar/gemini-cli/0.32.1", isDirectory: true)
        let cellarBin = cellarBase.appendingPathComponent("bin", isDirectory: true)
        let libexecBin = cellarBase.appendingPathComponent("libexec/bin", isDirectory: true)
        let oauthDir = cellarBase.appendingPathComponent(
            "libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist",
            isDirectory: true)

        // Create directories
        try fm.createDirectory(at: cellarBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: libexecBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: oauthDir, withIntermediateDirectories: true)

        // Write the oauth2.js file
        let oauthFile = oauthDir.appendingPathComponent("oauth2.js")
        try Self.sampleOAuth2JS.write(to: oauthFile, atomically: true, encoding: .utf8)

        // Final target: libexec/bin/gemini (regular file)
        let finalBinary = libexecBin.appendingPathComponent("gemini")
        try "#!/usr/bin/env node\n".write(to: finalBinary, atomically: true, encoding: .utf8)

        // Level 2 symlink: Cellar/…/bin/gemini → ../libexec/bin/gemini
        let cellarBinGemini = cellarBin.appendingPathComponent("gemini")
        try fm.createSymbolicLink(
            atPath: cellarBinGemini.path,
            withDestinationPath: "../libexec/bin/gemini")

        // Level 1 symlink: opt/homebrew/bin/gemini → ../Cellar/gemini-cli/0.32.1/bin/gemini
        let homebrewBin = root.appendingPathComponent("opt/homebrew/bin", isDirectory: true)
        try fm.createDirectory(at: homebrewBin, withIntermediateDirectories: true)
        let homebrewBinGemini = homebrewBin.appendingPathComponent("gemini")
        try fm.createSymbolicLink(
            atPath: homebrewBinGemini.path,
            withDestinationPath: "../Cellar/gemini-cli/0.32.1/bin/gemini")

        if includeExtraSymlink {
            // Level 0 symlink: usr/local/bin/gemini → <absolute>/opt/homebrew/bin/gemini
            let usrLocalBin = root.appendingPathComponent("usr/local/bin", isDirectory: true)
            try fm.createDirectory(at: usrLocalBin, withIntermediateDirectories: true)
            let usrLocalBinGemini = usrLocalBin.appendingPathComponent("gemini")
            try fm.createSymbolicLink(
                atPath: usrLocalBinGemini.path,
                withDestinationPath: homebrewBinGemini.path)
            return usrLocalBinGemini.path
        } else {
            return homebrewBinGemini.path
        }
    }

    // MARK: - Tests

    /// Standard 2-level Homebrew symlink chain (no extra symlink).
    /// The old code handled this correctly; this test guards against regressions.
    @Test
    func findsOAuthWithStandardHomebrewChain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiSymlinkTest-standard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let entryPath = try Self.makeBrewLayout(root: root, includeExtraSymlink: false)
        let content = GeminiStatusProbe.resolveOAuthFileContent(from: entryPath)

        #expect(content != nil, "Should find oauth2.js through standard 2-level Homebrew symlink chain")
        #expect(content?.contains("OAUTH_CLIENT_ID") == true)
        #expect(content?.contains("test-client-id") == true)
    }

    /// Multi-level symlink chain with an extra `/usr/local/bin` symlink.
    /// This is the scenario that caused the original bug — the old single-level
    /// `destinationOfSymbolicLink` resolved to `/opt/homebrew/bin/gemini` and
    /// computed `baseDir = /opt/homebrew`, missing the Cellar path entirely.
    @Test
    func findsOAuthWithExtraSymlinkLevel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiSymlinkTest-extra-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let entryPath = try Self.makeBrewLayout(root: root, includeExtraSymlink: true)
        let content = GeminiStatusProbe.resolveOAuthFileContent(from: entryPath)

        #expect(content != nil, "Should find oauth2.js through 3-level symlink chain (the bug scenario)")
        #expect(content?.contains("OAUTH_CLIENT_ID") == true)
        #expect(content?.contains("test-client-id") == true)
    }

    /// When the binary path is not a symlink at all (e.g. direct npm install),
    /// the resolver should still search relative to that path.
    @Test
    func handlesNonSymlinkBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiSymlinkTest-direct-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        // Create: root/bin/gemini (regular file) + root/lib/node_modules/…/oauth2.js
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("gemini")
        try "#!/usr/bin/env node\n".write(to: binary, atomically: true, encoding: .utf8)

        let oauthDir = root.appendingPathComponent(
            "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist",
            isDirectory: true)
        try fm.createDirectory(at: oauthDir, withIntermediateDirectories: true)
        try Self.sampleOAuth2JS.write(
            to: oauthDir.appendingPathComponent("oauth2.js"),
            atomically: true,
            encoding: .utf8)

        let content = GeminiStatusProbe.resolveOAuthFileContent(from: binary.path)
        #expect(content != nil, "Should find oauth2.js from non-symlinked binary")
    }

    /// Returns nil gracefully when no oauth2.js exists anywhere in the chain.
    @Test
    func returnsNilWhenOAuthFileMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiSymlinkTest-missing-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("gemini")
        try "#!/usr/bin/env node\n".write(to: binary, atomically: true, encoding: .utf8)

        let content = GeminiStatusProbe.resolveOAuthFileContent(from: binary.path)
        #expect(content == nil, "Should return nil when oauth2.js does not exist")
    }
}
