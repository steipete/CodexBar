import SwiftUI

private struct MenuItemHighlightedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct MenuCardRefreshMonitorKey: EnvironmentKey {
    static let defaultValue: MenuCardRefreshMonitor? = nil
}

extension EnvironmentValues {
    var menuItemHighlighted: Bool {
        get { self[MenuItemHighlightedKey.self] }
        set { self[MenuItemHighlightedKey.self] = newValue }
    }

    /// Optional live-refresh monitor injected into menu card views so the provider card
    /// subtitle can reflect the in-flight "Refreshing…" state in place while the NSMenu
    /// stays open, without rebuilding the menu during AppKit tracking.
    var menuCardRefreshMonitor: MenuCardRefreshMonitor? {
        get { self[MenuCardRefreshMonitorKey.self] }
        set { self[MenuCardRefreshMonitorKey.self] = newValue }
    }
}

enum MenuHighlightStyle {
    static let selectionText = Color(nsColor: .selectedMenuItemTextColor)
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

    static func progressTrack(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText.opacity(0.22) : Color(nsColor: .tertiaryLabelColor).opacity(0.22)
    }

    static func progressTint(_ highlighted: Bool, fallback: Color) -> Color {
        highlighted ? self.selectionText : fallback
    }

    static func selectionBackground(_ highlighted: Bool) -> Color {
        highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }
}
