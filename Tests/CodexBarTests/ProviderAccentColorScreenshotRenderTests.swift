import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders the accent color settings row and the recolored
/// usage bars to PNGs for documentation and pull requests.
///
/// The renders use an isolated settings store, so they never read the developer's own config and
/// never write to the shared App Group.
///
/// Run with:
///   CODEXBAR_ACCENT_SCREENSHOT_DIR=~/Downloads swift test --filter ProviderAccentColorScreenshotRenderTests
@MainActor
final class ProviderAccentColorScreenshotRenderTests: XCTestCase {
    private static let rowWidth: CGFloat = 460
    private static let barWidth: CGFloat = 320

    /// A deliberately unmistakable override, so a reviewer can tell at a glance that it took effect.
    private static let overrideHex = "#A56CC1"

    func test_renderAccentColorSettingsScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_ACCENT_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ACCENT_SCREENSHOT_DIR to render accent color screenshots.")
        }
        let directory = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let provider = UsageProvider.antigravity
        let defaultSettings = Self.settings(accentColor: nil, provider: provider)
        let overriddenSettings = Self.settings(accentColor: Self.overrideHex, provider: provider)

        let renders: [(String, AnyView)] = [
            ("accent-color-row-default", AnyView(Self.settingsRow(provider: provider, settings: defaultSettings))),
            ("accent-color-row-override", AnyView(Self.settingsRow(provider: provider, settings: overriddenSettings))),
            ("accent-color-bars-before-after", AnyView(Self.barComparison(provider: provider))),
        ]

        for (name, view) in renders {
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for \(name)")
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    private static func settings(accentColor: String?, provider: UsageProvider) -> SettingsStore {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: provider.instanceID, enabled: true, accentColor: accentColor),
        ])
        return testSettingsStore(
            suiteName: "ProviderAccentColorScreenshotRenderTests",
            config: config)
    }

    private static func settingsRow(provider: UsageProvider, settings: SettingsStore) -> some View {
        Form {
            ProviderAccentColorSettingsView(provider: provider, settings: settings)
        }
        .formStyle(.grouped)
        .frame(width: self.rowWidth)
    }

    /// Two bars in the shipped color and the override, so the effect reads without app chrome.
    private static func barComparison(provider: UsageProvider) -> some View {
        let shipped = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let overridden = ProviderColor(hexString: self.overrideHex) ?? shipped
        return VStack(alignment: .leading, spacing: 18) {
            self.labeledBar(title: "Default", color: shipped)
            self.labeledBar(title: "Override \(self.overrideHex)", color: overridden)
        }
        .padding(20)
        .frame(width: self.barWidth + 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func labeledBar(title: String, color: ProviderColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            UsageProgressBar(
                percent: 62,
                tint: Color(red: color.red, green: color.green, blue: color.blue),
                accessibilityLabel: title)
                .frame(width: self.barWidth, height: 8)
        }
    }

    /// Renders through an offscreen window. AppKit-backed controls such as the hex field and the
    /// color well draw nothing without one, so a windowless render shows an empty row.
    private static func pngData(for view: AnyView) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
