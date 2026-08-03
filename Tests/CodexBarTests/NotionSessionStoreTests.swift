import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)

struct NotionSessionStoreTests {
    @Test
    func `session files are owner only and round trip`() async throws {
        let (directory, fileURL) = try Self.makeSessionLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NotionSessionStore(fileURL: fileURL)
        await writer.setSession(tokenV2: "stored-token", sourceLabel: "Chrome")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)

        let reader = NotionSessionStore(fileURL: fileURL)
        let session = try #require(await reader.getSession())
        #expect(session.tokenV2 == "stored-token")
        #expect(session.cookieHeader == "token_v2=stored-token")
        #expect(session.sourceLabel == "Chrome")
    }

    @Test
    func `loading repairs legacy session file permissions`() async throws {
        let (directory, fileURL) = try Self.makeSessionLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NotionSessionStore(fileURL: fileURL)
        await writer.setSession(tokenV2: "legacy-token", sourceLabel: "Chrome")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let reader = NotionSessionStore(fileURL: fileURL)
        #expect(await reader.getSession()?.tokenV2 == "legacy-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    private static func makeSessionLocation() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-notion-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("notion-session.json"))
    }
}

#endif
