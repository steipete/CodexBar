import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutDisplayOptionsTests {
    @Test(arguments: MenuBarLayoutSize.allCases, MenuBarLayoutGap.allCases)
    func `size and gap selections remain accessible in a narrow row`(
        size: MenuBarLayoutSize,
        gap: MenuBarLayoutGap)
    {
        let hosting = Self.hostingView(width: 480, size: size, gap: gap)
        let text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)

        #expect(text.contains(L("menu_bar_layout_size")))
        #expect(text.contains(L("menu_bar_layout_gap")))
        #expect(text.contains(size.label))
        #expect(text.contains(gap.label))
    }

    @Test
    func `keyboard instructions remain in the footer without duplication in the row`() {
        let hosting = Self.hostingView(width: 720, size: .regular, gap: .regular)
        let text = MenuLayoutScreenshotRenderTests.accessibilityText(hosting)

        #expect(text.contains(L("menu_bar_layout_footer")))
        #expect(!text.contains("Delete removes the selected token"))
    }

    @Test
    func `synthetic display options screenshot`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_LAYOUT_OPTIONS_SCREENSHOT_DIR"]
        else { return }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [480, 520] {
                let hosting = Self.hostingView(width: width, size: .small, gap: .tight, appearance: appearance)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = appearance == .aqua ? "light" : "dark"
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("menu-bar-layout-options-\(Int(width))-\(name).png"))
            }
        }
    }

    private static func hostingView(
        width: CGFloat,
        size: MenuBarLayoutSize,
        gap: MenuBarLayoutGap,
        appearance: NSAppearance.Name = .aqua)
        -> NSHostingView<some View>
    {
        let view = VStack(alignment: .leading, spacing: 12) {
            MenuBarLayoutDisplayOptions(
                size: .constant(size),
                gap: .constant(gap),
                verticalAdjustment: .constant(0))
            SettingsSectionFooter(L("menu_bar_layout_footer"))
        }
        .padding(16)
        .frame(width: width)
        .environment(\.accessibilityEnabled, true)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }
}
