import Foundation
import os.lock
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

@Suite(.serialized)
struct AlibabaCodingPlanCookieImporterTests {
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
                    _ = try AlibabaChromiumCookieFallbackImporter.importSession(
                        browser: .chrome,
                        domains: ["example.com"])
                }
            }
        }
        #expect(keychainProbeCount.withLock { $0 } == 0)
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
