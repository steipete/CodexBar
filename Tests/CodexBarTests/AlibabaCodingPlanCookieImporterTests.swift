import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

struct AlibabaCodingPlanCookieImporterTests {
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

        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)
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
