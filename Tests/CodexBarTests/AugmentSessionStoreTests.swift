import Foundation
import Testing
@testable import CodexBarCore

struct AugmentSessionStoreTests {
    private enum PublishProbeError: Error {
        case stop
    }

    @Test
    func `new session files are owner only`() async throws {
        let (directory, fileURL) = try Self.makeSessionLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AugmentSessionStore(fileURL: fileURL)

        try await store.setCookies([Self.makeCookie(value: "new-session")])

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test
    func `loading repairs legacy session file permissions`() async throws {
        let (directory, fileURL) = try Self.makeSessionLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AugmentSessionStore(fileURL: fileURL)
        try await writer.setCookies([Self.makeCookie(value: "legacy-session")])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let reader = AugmentSessionStore(fileURL: fileURL)

        let cookies = await reader.getCookies()

        #expect(cookies.map(\.value) == ["legacy-session"])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test
    func `session cookies round trip through disk`() async throws {
        let (directory, fileURL) = try Self.makeSessionLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = AugmentSessionStore(fileURL: fileURL)
        try await writer.setCookies([Self.makeCookie(value: "round-trip")])
        let reader = AugmentSessionStore(fileURL: fileURL)

        let cookies = await reader.getCookies()

        #expect(cookies.count == 1)
        #expect(cookies.first?.name == "augment_session")
        #expect(cookies.first?.value == "round-trip")
        #expect(cookies.first?.domain == "app.augmentcode.com")
    }

    @Test
    func `failed staged write publishes nothing`() throws {
        let (directory, fileURL) = try Self.makeSessionLocation()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: PublishProbeError.stop) {
            try CredentialFileWriter.writePrivate(Data("session-cookie".utf8), to: fileURL) { stagedURL in
                let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
                let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
                #expect(permissions.intValue & 0o777 == 0o600)
                throw PublishProbeError.stop
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private static func makeSessionLocation() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-augment-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("augment-session.json"))
    }

    private static func makeCookie(value: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: "augment_session",
            .value: value,
            .domain: "app.augmentcode.com",
            .path: "/",
            .expires: Date(timeIntervalSince1970: 1_900_000_000),
            .secure: true,
        ]))
    }
}
