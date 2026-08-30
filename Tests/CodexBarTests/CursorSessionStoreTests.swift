import Foundation
import Testing
@testable import CodexBarCore

struct CursorSessionStoreTests {
    @Test
    func `session store saves and loads cookies`() async throws {
        let directory = Self.fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CursorSessionStore(fileURL: directory.appendingPathComponent("cursor-session.json"))
        try await store.setCookies([Self.cookie(name: "testCookie", value: "testValue")])
        let stored = await store.getCookies()
        #expect(stored.count == 1)
        #expect(stored.first?.name == "testCookie")
        #expect(stored.first?.value == "testValue")
        await store.clearCookies()
    }

    @Test
    func `session store reloads from disk when needed`() async throws {
        let directory = Self.fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("cursor-session.json")
        let writer = CursorSessionStore(fileURL: fileURL)
        try await writer.setCookies([Self.cookie(name: "diskCookie", value: "diskValue")])
        let reader = CursorSessionStore(fileURL: fileURL)
        let reloaded = await reader.getCookies()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.name == "diskCookie")
        #expect(reloaded.first?.value == "diskValue")
        await reader.clearCookies()
    }

    @Test
    func `session store has valid session loads from disk`() async throws {
        let directory = Self.fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("cursor-session.json")
        let writer = CursorSessionStore(fileURL: fileURL)
        try await writer.setCookies([Self.cookie(name: "validCookie", value: "validValue")])
        let reader = CursorSessionStore(fileURL: fileURL)
        #expect(await reader.hasValidSession())
        await reader.clearCookies()
        #expect(await !(reader.hasValidSession()))
    }

    private static func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-session-\(UUID().uuidString)", isDirectory: true)
    }

    private static func cookie(name: String, value: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name, .value: value, .domain: "cursor.com", .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600), .secure: true,
        ]))
    }
}
