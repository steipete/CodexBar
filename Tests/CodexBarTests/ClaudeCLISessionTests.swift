import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLISessionTests {
    @Test
    func `probe launch reuses one persisted session identifier`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)
        let second = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)

        #expect(first == second)
        #expect(ClaudeCLISession.launchArguments(sessionID: first) == [
            "--allowed-tools",
            "",
            "--session-id",
            first.uuidString.lowercased(),
        ])

        let file = directory.appendingPathComponent(".codexbar-session-id")
        let persisted = try String(contentsOf: file, encoding: .utf8)
        #expect(persisted == first.uuidString.lowercased())
        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        #endif
    }

    @Test
    func `invalid persisted probe session identifier is replaced`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(".codexbar-session-id")
        try "invalid".write(to: file, atomically: true, encoding: .utf8)

        let sessionID = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)
        let persisted = try String(contentsOf: file, encoding: .utf8)

        #expect(persisted == sessionID.uuidString.lowercased())
    }

    @Test
    func `unwritable probe directory keeps one process local fallback identifier`() {
        let directory = URL(fileURLWithPath: "/dev/null/CodexBar-ClaudeProbe", isDirectory: true)

        let first = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)
        let second = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)

        #expect(first == second)
    }
}
