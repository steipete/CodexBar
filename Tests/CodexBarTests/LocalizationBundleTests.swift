import Foundation
import Testing
@testable import CodexBar

struct LocalizationBundleTests {
    @Test
    func `packaged app resolves localization bundle from resources`() throws {
        let fixture = try Self.makeAppBundleFixture(includeLocalizationBundle: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let bundle = codexBarLocalizationResourceBundle(mainBundle: fixture.appBundle)

        #expect(bundle.bundleURL.lastPathComponent == "CodexBar_CodexBar.bundle")
        #expect(bundle.path(forResource: "en", ofType: "lproj") != nil)
    }

    @Test
    func `packaged app falls back to main bundle without touching SwiftPM module`() throws {
        let fixture = try Self.makeAppBundleFixture(includeLocalizationBundle: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let bundle = codexBarLocalizationResourceBundle(mainBundle: fixture.appBundle)

        #expect(bundle.bundleURL == fixture.appBundle.bundleURL)
    }

    private static func makeAppBundleFixture(
        includeLocalizationBundle: Bool) throws -> (root: URL, appBundle: Bundle)
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-localization-\(UUID().uuidString)",
            isDirectory: true)
        let appURL = root.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>CodexBar</string>
            <key>CFBundleIdentifier</key><string>com.steipete.codexbar.tests</string>
            <key>CFBundleName</key><string>CodexBar</string>
            <key>CFBundlePackageType</key><string>APPL</string>
        </dict>
        </plist>
        """
        try info.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8)

        if includeLocalizationBundle {
            let lprojURL = resourcesURL
                .appendingPathComponent("CodexBar_CodexBar.bundle", isDirectory: true)
                .appendingPathComponent("en.lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: true)
            try "\"Settings\" = \"Settings\";\n".write(
                to: lprojURL.appendingPathComponent("Localizable.strings"),
                atomically: true,
                encoding: .utf8)
        }

        let appBundle = try #require(Bundle(url: appURL))
        return (root, appBundle)
    }
}
