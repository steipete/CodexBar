import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthCredentialsStorePermissionsTests {
    private enum PublishProbeError: Error, Equatable {
        case stop
    }

    @Test
    func `saving O auth credentials keeps auth json private`() throws {
        #if os(macOS) || os(Linux)
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-123",
            lastRefresh: Date())

        try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": codexHome.path])

        let authURL = codexHome.appendingPathComponent("auth.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: authURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `auth json is private before atomic publication`() throws {
        #if os(macOS) || os(Linux)
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let authURL = codexHome.appendingPathComponent("auth.json")
        let originalData = Data("original".utf8)
        try originalData.write(to: authURL)

        #expect(throws: PublishProbeError.stop) {
            try CodexOAuthCredentialsStore._writePrivateFileForTesting(
                Data("replacement".utf8),
                to: authURL)
            { stagedURL in
                let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
                let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
                #expect(permissions.intValue & 0o777 == 0o600)
                #expect(try Data(contentsOf: authURL) == originalData)
                throw PublishProbeError.stop
            }
        }

        #expect(try Data(contentsOf: authURL) == originalData)
        let entries = try FileManager.default.contentsOfDirectory(atPath: codexHome.path)
        #expect(entries == ["auth.json"])
        #else
        #expect(Bool(true))
        #endif
    }
}
