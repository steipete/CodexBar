import Foundation
import os.lock
import Security
import SQLite3
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

@Suite(.serialized)
struct AlibabaCodingPlanCookieImporterTests {
    @Test
    func `shared OSCrypt keeps legacy and domain prefixed cookies readable`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(
            db,
            """
            CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, expires_utc INTEGER,
            is_secure INTEGER, value TEXT, encrypted_value BLOB);
            """,
            nil,
            nil,
            nil) == SQLITE_OK)
        for (name, bytes) in [
            ("legacy", Data("legacy-session".utf8)),
            ("hashed", Data(repeating: 0xFF, count: 32) + Data("hashed-session".utf8)),
        ] {
            let secure = name == "hashed" ? 1 : 0
            let envelope = try CursorAppAuthEncryptionTests.envelope(bytes)
            let encoded = String(envelope.dropFirst("cursor-safe-storage:v1:".count))
            let encrypted = try #require(Data(base64Encoded: encoded)).map { String(format: "%02x", $0) }.joined()
            try #require(sqlite3_exec(
                db,
                """
                INSERT INTO cookies VALUES('.example.com', '\(name)', '/', 0, \(secure), '', X'\(encrypted)');
                """,
                nil,
                nil,
                nil) == SQLITE_OK)
        }
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let lookup: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            #expect(query[kSecUseAuthenticationUI as String] as? String ==
                KeychainNoUIQuery.uiFailPolicyForTesting())
            return (errSecSuccess, Data(CursorAppAuthEncryptionTests.password.utf8))
        }
        let session = try KeychainAccessGate.withTaskOverrideForTesting(false) {
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                try BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(true) {
                    try ChromiumSafeStorage.$readOverrideForTesting.withValue(lookup) {
                        try AliyunOneConsoleChromiumCookieFallbackImporter.importSession(
                            browser: .chrome,
                            domains: ["example.com"],
                            isAuthenticatedSession: { !$0.isEmpty },
                            sessionLabel: "Synthetic",
                            cookieClient: client)
                    }
                }
            }
        }
        #expect(session?.cookies.map(\.value).sorted() == ["hashed-session", "legacy-session"])
        #expect(session?.cookies.first(where: { $0.name == "legacy" })?.isSecure == false)
        #expect(session?.cookies.first(where: { $0.name == "hashed" })?.isSecure == true)
    }

    @Test
    func `unrelated fallback cookie rows never request Safe Storage`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(
            db,
            """
            CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, expires_utc INTEGER,
            is_secure INTEGER, value TEXT, encrypted_value BLOB);
            INSERT INTO cookies VALUES('unrelated.example', 'session', '/', 0, 1, '', X'763130');
            """,
            nil,
            nil,
            nil) == SQLITE_OK)
        let attempts = LockIsolated(0)
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                attempts.setValue(attempts.value + 1)
                return .interactionRequired
            } operation: {
                BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(true) {
                    let session = try? AliyunOneConsoleChromiumCookieFallbackImporter.importSession(
                        browser: .chrome,
                        domains: ["example.com"],
                        isAuthenticatedSession: { !$0.isEmpty },
                        sessionLabel: "Synthetic",
                        cookieClient: client)
                    #expect(session == nil)
                }
            }
        }
        #expect(attempts.value == 0)
    }

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment[BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey] == "1",
        "Default-home cookie access is explicitly enabled for this test run."))
    func `default home import is suppressed before profile and keychain access`() throws {
        let profileProbeCount = OSAllocatedUnfairLock(initialState: 0)
        let keychainProbeCount = OSAllocatedUnfairLock(initialState: 0)
        let defaultHome = try #require(BrowserCookieClient.defaultHomeDirectories().first)
        let detection = BrowserDetection(
            homeDirectory: defaultHome.path,
            cacheTTL: 0,
            fileExists: { _ in
                profileProbeCount.withLock { $0 += 1 }
                return true
            },
            directoryContents: { _ in
                profileProbeCount.withLock { $0 += 1 }
                return ["Default"]
            })

        _ = KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                keychainProbeCount.withLock { $0 += 1 }
                return .allowed
            } operation: {
                #expect(throws: AlibabaCodingPlanSettingsError.self) {
                    _ = try AlibabaCodingPlanCookieImporter.importSession(browserDetection: detection)
                }
            }
        }

        #expect(profileProbeCount.withLock { $0 } == 0)
        #expect(keychainProbeCount.withLock { $0 } == 0)
    }

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment[BrowserCookieAccessGate.allowTestCookieAccessEnvironmentKey] == "1",
        "Default-home cookie access is explicitly enabled for this test run."))
    func `chromium fallback rejects default client before keychain access`() {
        let keychainProbeCount = OSAllocatedUnfairLock(initialState: 0)
        _ = KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                keychainProbeCount.withLock { $0 += 1 }
                return .allowed
            } operation: {
                #expect(throws: BrowserCookieStoreAccessSuppressedError.self) {
                    _ = try AliyunOneConsoleChromiumCookieFallbackImporter.importSession(
                        browser: .chrome,
                        domains: ["example.com"],
                        isAuthenticatedSession: { _ in false },
                        sessionLabel: "Test")
                }
            }
        }
        #expect(keychainProbeCount.withLock { $0 } == 0)
    }

    @Test
    func `chromium fallback keeps its browser denial gate after metadata discovery`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("Cookies"))
        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        try BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(false) {
            #expect(try client.codexBarStores(for: .chrome).count == 1)
            let result = try AliyunOneConsoleChromiumCookieFallbackImporter.importSession(
                browser: .chrome,
                domains: ["example.com"],
                isAuthenticatedSession: { _ in Issue.record("Must not read cookies"); return false },
                sessionLabel: "Synthetic",
                cookieClient: client,
                logger: { _ in Issue.record("Must not start fallback decryption") })
            #expect(result == nil)
        }
    }

    @Test
    func `domain matching requires exact or label bounded suffix`() {
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("console.aliyun.com"))
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain(".modelstudio.console.alibabacloud.com"))
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("foo.aliyun.com"))
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("evilaliyun.com") == false)
        #expect(AlibabaCodingPlanCookieImporter.matchesCookieDomain("notalibabacloud.com") == false)
    }

    @Test
    func `cookie import candidates honor provided browser order`() throws {
        BrowserCookieAccessGate.resetForTesting()

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let firefoxProfile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
            .appendingPathComponent("Profiles")
            .appendingPathComponent("abc.default-release")
        try FileManager.default.createDirectory(at: firefoxProfile, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: firefoxProfile.appendingPathComponent("cookies.sqlite").path,
            contents: Data())

        let detection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            fileExists: { path in
                path == "/Applications/Firefox.app" || FileManager.default.fileExists(atPath: path)
            })
        let importOrder: BrowserCookieImportOrder = [.firefox, .safari, .chrome]

        let candidates = AlibabaCodingPlanCookieImporter.cookieImportCandidates(
            browserDetection: detection,
            importOrder: importOrder)

        let expected: [Browser] = [.firefox, .safari]
        #expect(candidates == expected)
    }

    @Test
    func `default cookie import candidates skip keychain browsers during tests`() throws {
        BrowserCookieAccessGate.resetForTesting()

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let chromeProfile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")
            .appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: chromeProfile, withIntermediateDirectories: true)
        let cookiesDir = chromeProfile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: cookiesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: cookiesDir.appendingPathComponent("Cookies").path,
            contents: Data())

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        let candidates = AlibabaCodingPlanCookieImporter.cookieImportCandidates(browserDetection: detection)

        #expect(candidates.first == .safari)
        #expect(candidates.contains(.chrome) == false)
    }
}

#else

struct AlibabaCodingPlanCookieImporterTests {
    @Test
    func `non mac OS placeholder`() {
        #expect(true)
    }
}

#endif
