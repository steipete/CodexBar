import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CodexOAuthCredentialsStoreLinuxTests {
    @Test
    func saveKeepsAuthJSONPrivate() throws {
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
}
