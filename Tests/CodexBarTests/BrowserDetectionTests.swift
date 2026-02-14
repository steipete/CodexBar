import CodexBarCore
import Foundation
import Testing

#if os(macOS)
import SweetCookieKit

@Suite
struct BrowserDetectionTests {
    @Test
    func safariAlwaysInstalled() {
        #expect(BrowserDetection(cacheTTL: 0).isAppInstalled(.safari) == true)
        #expect(BrowserDetection(cacheTTL: 0).isCookieSourceAvailable(.safari) == true)
    }

    @Test
    func filterInstalledIncludesSafari() {
        let detection = BrowserDetection(cacheTTL: 0)
        let browsers: [Browser] = [.safari, .chrome, .firefox]
        #expect(browsers.cookieImportCandidates(using: detection).contains(.safari))
    }

    @Test
    func filterPreservesOrder() {
        BrowserCookieAccessGate.resetForTesting()

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let firefoxProfile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
            .appendingPathComponent("Profiles")
            .appendingPathComponent("abc.default-release")
        try? FileManager.default.createDirectory(at: firefoxProfile, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: firefoxProfile.appendingPathComponent("cookies.sqlite").path,
            contents: Data())

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        let browsers: [Browser] = [.firefox, .safari, .chrome]
        // Chrome is filtered out deterministically because it lacks usable on-disk profile/cookie store data.
        #expect(browsers.cookieImportCandidates(using: detection) == [.firefox, .safari])
    }

    @Test
    func chromeRequiresProfileData() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.chrome) == false)

        let profile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")
            .appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let cookiesDir = profile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: cookiesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cookiesDir.appendingPathComponent("Cookies").path, contents: Data())

        #expect(detection.isCookieSourceAvailable(.chrome) == true)
    }

    @Test
    func diaRequiresProfileData() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.dia) == false)

        let profile = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Dia")
            .appendingPathComponent("User Data")
            .appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let cookiesDir = profile.appendingPathComponent("Network")
        try FileManager.default.createDirectory(at: cookiesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cookiesDir.appendingPathComponent("Cookies").path, contents: Data())

        #expect(detection.isCookieSourceAvailable(.dia) == true)
    }

    @Test
    func firefoxRequiresDefaultProfileDir() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let profiles = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
            .appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
        #expect(detection.isCookieSourceAvailable(.firefox) == false)

        let profile = profiles.appendingPathComponent("abc.default-release")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: profile.appendingPathComponent("cookies.sqlite").path, contents: Data())
        #expect(detection.isCookieSourceAvailable(.firefox) == true)
    }
}

#else

@Suite
struct BrowserDetectionTests {
    @Test
    func nonMacOSReturnsNoBrowsers() {
        #expect(BrowserDetection(cacheTTL: 0).isCookieSourceAvailable(Browser()) == false)
    }

    @Test
    func nonMacOSFilterReturnsEmpty() {
        let detection = BrowserDetection(cacheTTL: 0)
        let browsers = [Browser(), Browser()]
        #expect(browsers.cookieImportCandidates(using: detection).isEmpty == true)
    }
}

#endif
