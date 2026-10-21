import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct AboutWebsiteTests {
    @Test
    func `website link matches the published project domain`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let domain = try String(contentsOf: root.appendingPathComponent("docs/CNAME"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try Self.websiteURL() == "https://\(domain)")
    }

    @Test
    func `about links render without opening a browser`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_ABOUT_WEBSITE_PROOF_DIR"] else { return }
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let url = try Self.websiteURL()
            let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 16) {
                AboutLinkRow(icon: "globe", title: L("link_website"), url: url)
                Divider()
                Text("Configured destination (proof annotation)").font(.caption)
                Text(url).font(.system(.body, design: .monospaced))
            }
            .padding(24)
            .frame(width: 530)
            .environment(\.colorScheme, .light)
            .background(Color.white))
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appendingPathComponent("about.png"))
        }
    }

    private static func websiteURL() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesAboutPane.swift"), encoding: .utf8)
        let pattern = #"title:\s*L\("link_website"\),\s*url:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        let range = try #require(Range(match.range(at: 1), in: source))
        return String(source[range])
    }
}
