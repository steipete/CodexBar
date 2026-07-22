import Foundation
import Testing
@testable import CodexBarCore

/// Regression guard for the provider credential-file hardening. `CredentialFileWriter` must create
/// credential files owner-only (0600), publish atomically, and repair a pre-existing world-readable
/// file. It is cross-platform (POSIX modes) and mutates no shared state, so it compiles and runs on
/// the Linux CI test jobs and under `swift test --parallel` without racing other suites.
struct CredentialFileWriterTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rk-cfw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test
    func `writes credential file owner only`() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("factory-session.json")

        try CredentialFileWriter.writePrivate(Data(#"{"bearerToken":"secret"}"#.utf8), to: url)

        #expect(try self.mode(of: url) == 0o600, "a credential file must be created owner-only (0600)")
        let staged = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("codexbar-staged") }
        #expect(staged.isEmpty, "no staged temp file should remain after publish")
    }

    @Test
    func `overwrite replaces atomically and stays private`() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cursor-session.json")

        try CredentialFileWriter.writePrivate(Data("v1".utf8), to: url)
        try CredentialFileWriter.writePrivate(Data("v2".utf8), to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "v2")
        #expect(try self.mode(of: url) == 0o600)
    }

    @Test
    func `repairs legacy world readable file`() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy-session.json")

        // Simulate a session file written 0644 by an earlier build.
        try Data("legacy".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try self.mode(of: url) == 0o644)

        CredentialFileWriter.repairPermissions(at: url)
        #expect(try self.mode(of: url) == 0o600, "an existing 0644 credential file must be repaired to 0600")
    }
}
