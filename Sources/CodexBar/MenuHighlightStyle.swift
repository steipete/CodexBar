import AppKit
import CodexBarCore
import SwiftUI

extension EnvironmentValues {
    @Entry var menuItemHighlighted: Bool = false
    /// Optional live-refresh monitor injected into menu card views so the provider card
    /// subtitle can reflect the in-flight "Refreshing…" state in place while the NSMenu
    /// stays open, without rebuilding the menu during AppKit tracking.
    @Entry var menuCardRefreshMonitor: MenuCardRefreshMonitor?
}

enum MenuHighlightStyle {
    static let enabledKey = "customMenuHighlightEnabled"
    static let colorKey = "customMenuHighlightColor"
    static let opacityKey = "customMenuHighlightOpacity"
    static let defaultColor = ProviderColor(hex: 0x78A9E8)
    static let defaultOpacity = 0.30

    static func customAppearance(defaults: UserDefaults = .standard) -> (color: ProviderColor, opacity: Double)? {
        guard defaults.bool(forKey: self.enabledKey) else { return nil }
        let color = defaults.string(forKey: self.colorKey)
            .flatMap(ProviderColor.init(hexString:)) ?? self.defaultColor
        let opacity = defaults.object(forKey: self.opacityKey) as? Double ?? self.defaultOpacity
        return (color, min(1, max(0, opacity.isFinite ? opacity : self.defaultOpacity)))
    }

    static var selectionTextColor: NSColor {
        guard let appearance = self.customAppearance() else { return .selectedMenuItemTextColor }
        // A translucent fill leaves the menu background visible. Keep the normal label contrast there.
        guard appearance.opacity >= 0.65 else { return .labelColor }
        let luminance = 0.2126 * appearance.color.red + 0.7152 * appearance.color.green
            + 0.0722 * appearance.color.blue
        return luminance > 0.6 ? .black : .white
    }

    static var selectionText: Color {
        Color(nsColor: self.selectionTextColor)
    }

    static let normalPrimaryText = Color(nsColor: .controlTextColor)
    static let normalSecondaryText = Color(nsColor: .secondaryLabelColor)

    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalPrimaryText
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalSecondaryText
    }

    static func error(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : Color(nsColor: .systemRed)
    }

    /// Emphasis for a card's status label (for example the active account).
    /// A highlighted row still uses the selection color so contrast is kept.
    static func accent(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : Color(nsColor: .controlAccentColor)
    }

    static func progressTrack(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText.opacity(0.22) : Color(nsColor: .tertiaryLabelColor).opacity(0.22)
    }

    static func progressTint(_ highlighted: Bool, fallback: Color) -> Color {
        highlighted ? self.selectionText : fallback
    }

    static func selectionBackground(_ highlighted: Bool) -> Color {
        guard highlighted else { return .clear }
        guard let appearance = self.customAppearance() else {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        return Color(red: appearance.color.red, green: appearance.color.green, blue: appearance.color.blue)
            .opacity(appearance.opacity)
    }

    static func makeSelectionView() -> NSView {
        if let appearance = self.customAppearance() {
            let view = NSView()
            view.wantsLayer = true
            self.updateSelectionView(view, appearance: appearance)
            return view
        }
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    static func updateSelectionView(_ view: NSView) {
        guard let appearance = self.customAppearance() else { return }
        self.updateSelectionView(view, appearance: appearance)
    }

    private static func updateSelectionView(_ view: NSView, appearance: (color: ProviderColor, opacity: Double)) {
        view.layer?.backgroundColor = NSColor(
            srgbRed: appearance.color.red,
            green: appearance.color.green,
            blue: appearance.color.blue,
            alpha: appearance.opacity).cgColor
    }
}
