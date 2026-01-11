import Foundation
import Testing

#if os(macOS)
import SweetCookieKit
@testable import CodexBarCore

@Suite
struct ClaudeBrowserCatalogTests {
    @Test
    func decodeCatalogDefaults() throws {
        let json = """
        {
          "chromium": [
            {
              "id": "test",
              "displayName": "Test Browser",
              "profileRootRelative": [
                "Application Support/Test"
              ],
              "cookiePathPatterns": [
                "Default/Cookies"
              ]
            }
          ],
          "firefox": [],
          "webkit": [],
          "safari": []
        }
        """
        let data = try #require(json.data(using: .utf8))
        let catalog = try ClaudeBrowserCatalog.decode(from: data)
        #expect(catalog.chromium.count == 1)
        #expect(catalog.chromium[0].bundleIDs.isEmpty)
        #expect(catalog.chromium[0].appNameHints.isEmpty)
    }

    @Test
    func chromiumPatternExpansion() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let root = temp
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("TestBrowser")
        let defaultProfile = root.appendingPathComponent("Default")
        let defaultNetwork = defaultProfile.appendingPathComponent("Network")
        let profile1 = root.appendingPathComponent("Profile 1")

        try FileManager.default.createDirectory(at: defaultNetwork, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile1, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: defaultProfile.appendingPathComponent("Cookies").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: defaultNetwork.appendingPathComponent("Cookies").path,
            contents: Data())
        FileManager.default.createFile(
            atPath: profile1.appendingPathComponent("Cookies").path,
            contents: Data())

        let entry = ClaudeBrowserCatalog.BrowserEntry(
            id: "test",
            displayName: "Test Browser",
            profileRootRelative: ["Application Support/TestBrowser"],
            cookiePathPatterns: [
                "Default/Cookies",
                "Default/Network/Cookies",
                "Profile */Cookies",
            ])
        let catalog = ClaudeBrowserCatalog(chromium: [entry], firefox: [], webkit: [], safari: [])
        let candidates = ClaudeWebAPIFetcher._cookieStoreCandidatesForTesting(
            catalog: catalog,
            homeDirectories: [temp])

        #expect(candidates.count == 3)
        let labels = Set(candidates.map(\.label))
        #expect(labels.contains("Test Browser Default"))
        #expect(labels.contains("Test Browser Default (Network)"))
        #expect(labels.contains("Test Browser Profile 1"))

        let network = candidates.first { $0.label == "Test Browser Default (Network)" }
        #expect(network?.kind == .network)
    }

    @Test
    func warningSummaryCompactsByBrowser() {
        var report = CookieExtractionReport()
        report.append(.init(
            level: .warning,
            browser: "Safari",
            category: .cookieFileUnreadable,
            message: "Permission denied"))
        report.append(.init(
            level: .warning,
            browser: "Safari",
            category: .cookieFileUnreadable,
            message: "Permission denied"))
        report.append(.init(
            level: .warning,
            browser: "Chrome",
            category: .noCookieFiles,
            message: "Missing"))

        let summary = report.compactWarningSummary()
        #expect(summary?.contains("Safari: permission denied (2)") == true)
        #expect(summary?.contains("Chrome: cookies missing") == true)
    }
}

#else

@Suite
struct ClaudeBrowserCatalogTests {
    @Test
    func nonMacOSNoOp() {
        #expect(true)
    }
}
#endif
