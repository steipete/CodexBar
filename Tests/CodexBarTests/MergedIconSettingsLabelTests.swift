import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MergedIconSettingsLabelTests {
    @Test(arguments: [false, true])
    func `disabled row titles have lower contrast and remain readable`(dark: Bool) throws {
        let enabled = try Self.titleContrast(enabled: true, dark: dark)
        let disabled = try Self.titleContrast(enabled: false, dark: dark)
        #expect(disabled < enabled)
        #expect(disabled >= 3)
    }

    @Test(arguments: [false, true])
    func `disabled row titles and subtitles remain accessible`(enabled: Bool) {
        let hosting = NSHostingView(rootView: SettingsRowLabel("Synthetic title", subtitle: "Synthetic explanation")
            .disabled(!enabled)
            .environment(\.accessibilityEnabled, true))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
        #expect(text.contains("Synthetic title"))
        #expect(text.contains("Synthetic explanation"))
    }

    @Test
    func `merged labels and layout options remain accessible in synthetic settings renders`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for mode in ["off", "switcher", "stacked"] {
                let merged = mode != "off"
                let presentation = MergedIconPresentation(
                    mergeIcons: merged,
                    iconStyle: .iconAndPercent,
                    requestedStyle: mode == "stacked" ? .stacked : .switcher,
                    eligibleProviders: [.codex, .claude],
                    preferredTop: nil,
                    preferredBottom: nil)
                for dark in [false, true] {
                    let view = VStack(alignment: .leading, spacing: 18) {
                        Text(L("section_combined_icon")).font(.headline)
                        Toggle(isOn: .constant(merged)) {
                            SettingsRowLabel(L("merge_icons_title"), subtitle: L("merge_icons_subtitle"))
                        }
                        SettingsMenuPicker(
                            selection: .constant(presentation.effectiveStyle),
                            options: MenuBarSettingsMenuOptions.mergedIconStyles,
                            label: {
                                SettingsRowLabel(
                                    L("merged_icon_style_title"), subtitle: L("merged_icon_style_subtitle"))
                            },
                            optionLabel: { Text($0.label) })
                            .disabled(!presentation.canStack)
                        SettingsMenuPicker(
                            selection: .constant(MenuBarSettingsMenuOptions.switcherRows[0]),
                            options: MenuBarSettingsMenuOptions.switcherRows,
                            label: { SettingsRowLabel(L("switcher_rows_title")) },
                            optionLabel: { Text($0.label) })
                            .disabled(!merged)
                        UnifiedIconSourcePicker(selection: .constant(.frontmostApp))
                            .disabled(!merged || presentation.effectiveStyle == .stacked)
                        SettingsRowLabel(
                            L("overview_tab_providers_title"),
                            subtitle: merged ? "Codex, Claude" : L("overview_enable_merge_icons_hint"))
                            .disabled(!merged)
                        Divider()
                        MenuBarLayoutDisplayOptions(
                            size: .constant(.small),
                            gap: .constant(.tight),
                            verticalAdjustment: .constant(0),
                            monospacedDigits: .constant(false),
                            showWindowLabels: .constant(true))
                    }
                    .toggleStyle(.switch)
                    .padding(24)
                    .frame(width: 520)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.accessibilityEnabled, true)
                    .background(Color(nsColor: .windowBackgroundColor))
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
                    hosting.layoutSubtreeIfNeeded()
                    let text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)
                    for key in [
                        "merge_icons_title", "merged_icon_style_title", "switcher_rows_title",
                        "merged_icon_source_title", "merged_icon_source_frontmost_app", "overview_tab_providers_title",
                        "menu_bar_layout_size", "menu_bar_layout_gap",
                    ] {
                        #expect(text.contains(L(key)), "Missing accessible label: \(key) in \(mode)")
                    }
                    if let directory = ProcessInfo.processInfo.environment["CODEXBAR_MERGED_LABEL_PROOF_DIR"] {
                        let output = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent(
                            "merged-\(mode)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    private static func titleContrast(enabled: Bool, dark: Bool) throws -> Double {
        let renderer = ImageRenderer(content: SettingsRowLabel("Merged icon style")
            .disabled(!enabled)
            .padding(12)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color.black : Color.white))
        renderer.scale = 2
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        var contrast = 1.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let channels = [color.redComponent, color.greenComponent, color.blueComponent].map {
                    $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
                }
                let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
                contrast = max(contrast, dark ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05))
            }
        }
        return contrast
    }
}
