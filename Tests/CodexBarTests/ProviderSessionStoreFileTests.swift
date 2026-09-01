import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderSessionStoreFileTests {
    @Test(arguments: ["swiftpm-testing-helper", "CodexBarPackageTests", "CodexBarPackageTests.xctest"])
    func `process names isolate session files even when real Keychain is allowed`(processName: String) {
        let root = URL(fileURLWithPath: "/synthetic/session-tests")
        let url = ProviderSessionStoreFile.url(
            for: "fixture.json",
            processName: processName,
            environment: ["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1"],
            testDirectory: root,
            applicationSupportDirectory: {
                Issue.record("Test path selection consulted user Application Support")
                return URL(fileURLWithPath: "/synthetic/user")
            })
        #expect(url == root.appendingPathComponent("fixture.json"))
    }

    @Test(arguments: [
        "XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
        "TESTING_LIBRARY_VERSION", "SWIFT_TESTING", "SWIFT_TESTING_ENABLED",
        "CODEXBAR_TEST_SESSION_FILE_ISOLATION",
    ])
    func `runtime markers and child process signals isolate session files`(marker: String) {
        let root = URL(fileURLWithPath: "/synthetic/session-tests")
        let url = ProviderSessionStoreFile.url(
            for: "fixture.json",
            processName: "CodexBarCLI",
            environment: [marker: "1"],
            testDirectory: root,
            applicationSupportDirectory: {
                Issue.record("A test child consulted user Application Support")
                return URL(fileURLWithPath: "/synthetic/user")
            })
        #expect(url == root.appendingPathComponent("fixture.json"))
    }

    @Test
    func `ordinary execution retains the production relative path using a fake root`() {
        let root = URL(fileURLWithPath: "/synthetic/Application Support", isDirectory: true)
        for filename in ["cursor-session.json", "augment-session.json", "factory-session.json", "notion-session.json"] {
            let url = ProviderSessionStoreFile.url(
                for: filename,
                processName: "CodexBar",
                environment: [:],
                applicationSupportDirectory: { root })
            #expect(url == root.appendingPathComponent("CodexBar").appendingPathComponent(filename))
        }
    }

    @Test
    func `all default provider session stores persist only in the process test directory`() async throws {
        let files = ["cursor-session.json", "augment-session.json", "factory-session.json", "notion-session.json"]
            .map { ProviderSessionStoreFile.url(for: $0) }
        #expect(Set(files.map { $0.deletingLastPathComponent() }).count == 1)
        #expect(files
            .allSatisfy { $0.deletingLastPathComponent().lastPathComponent.hasPrefix("codexbar-session-tests-") })
        defer { for file in files {
            try? FileManager.default.removeItem(at: file)
        } }
        let cookie = try Self.cookie(value: "synthetic-default")
        let cursor = CursorSessionStore()
        let augment = AugmentSessionStore()
        let factory = FactorySessionStore()
        let notion = NotionSessionStore()
        await cursor.setCookies([cookie])
        await augment.setCookies([cookie])
        await factory.setCookies([cookie])
        await notion.setSession(tokenV2: "synthetic-notion", sourceLabel: "Fixture")
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
        }
        #expect(await CursorSessionStore().getCookies().map(\.value) == ["synthetic-default"])
        #expect(await AugmentSessionStore().getCookies().map(\.value) == ["synthetic-default"])
        #expect(await FactorySessionStore().getCookies().map(\.value) == ["synthetic-default"])
        #expect(await NotionSessionStore().getSession()?.tokenV2 == "synthetic-notion")
        await cursor.clearCookies()
        await augment.clearCookies()
        await factory.clearSession()
        await notion.clearSession()
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test
    func `Cursor fixture reload repairs permissions and prunes expired cookies`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-session-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cursor-session.json")
        let writer = CursorSessionStore(fileURL: file)
        try await writer.setCookies([
            Self.cookie(value: "active"),
            Self.cookie(value: "expired", expires: Date(timeIntervalSince1970: 1)),
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let reader = CursorSessionStore(fileURL: file)
        #expect(await reader.getCookies().map(\.value) == ["active"])
        #expect(await CursorSessionStore(fileURL: file).getCookies().map(\.value) == ["active"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        await reader.clearCookies()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    private static func cookie(value: String, expires: Date = Date(timeIntervalSinceNow: 3600)) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: "fixture", .value: value, .domain: "session.test", .path: "/", .expires: expires, .secure: true,
        ]))
    }
}
