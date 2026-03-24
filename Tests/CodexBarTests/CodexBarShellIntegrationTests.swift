import Foundation
import Testing
@testable import CodexBar

struct CodexBarShellIntegrationTests {
    @Test
    func `ensure dedicated sessions directory creates account root once`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let accountRoot = root.appendingPathComponent("account", isDirectory: true)
        try fm.createDirectory(at: accountRoot, withIntermediateDirectories: true)

        CodexBarShellIntegration.ensureDedicatedSessionsDirectoryIfNeeded(
            into: accountRoot.path,
            fileManager: fm)
        CodexBarShellIntegration.ensureDedicatedSessionsDirectoryIfNeeded(
            into: accountRoot.path,
            fileManager: fm)

        let sessions = accountRoot.appendingPathComponent("sessions", isDirectory: true)
        #expect(fm.fileExists(atPath: sessions.path))
        let values = try sessions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        #expect(values.isDirectory == true)
        #expect(values.isSymbolicLink != true)
    }

    @Test
    func `ensure dedicated sessions directory replaces legacy shared symlink`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let defaultSessions = root
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: defaultSessions, withIntermediateDirectories: true)

        let accountRoot = root.appendingPathComponent("account", isDirectory: true)
        try fm.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        let sessions = accountRoot.appendingPathComponent("sessions", isDirectory: true)
        try fm.createSymbolicLink(at: sessions, withDestinationURL: defaultSessions)

        CodexBarShellIntegration.ensureDedicatedSessionsDirectoryIfNeeded(
            into: accountRoot.path,
            fileManager: fm,
            defaultSessionsRoot: defaultSessions)

        let values = try sessions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        #expect(values.isDirectory == true)
        #expect(values.isSymbolicLink != true)
    }

    @Test
    func `set active codex home writes and clears override file`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        CodexBarShellIntegration.setActiveCodexHome(
            "/tmp/codex-work",
            fileManager: fm,
            codexbarDirectory: root)

        let activeFile = root.appendingPathComponent("active-codex-home")
        let contents = try String(contentsOf: activeFile, encoding: .utf8)
        #expect(contents == "/tmp/codex-work")

        CodexBarShellIntegration.setActiveCodexHome(
            nil,
            fileManager: fm,
            codexbarDirectory: root)

        #expect(fm.fileExists(atPath: activeFile.path) == false)
    }
}
