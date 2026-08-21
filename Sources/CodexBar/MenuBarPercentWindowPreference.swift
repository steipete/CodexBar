import Foundation

/// Which quota window the menu bar percent reads from, expressed as a single choice.
///
/// The menu bar renders from a `MenuBarLayout`, whose `%` tokens each carry their own
/// `PercentWindow`. That is expressive but only reachable through the layout editor, so an account
/// whose stored preference resolves to the weekly lane can end up showing a nearly-full weekly
/// percent with no obvious way to switch to the session lane. This maps the common case — every
/// percent in the layout reading the same window — onto one picker.
///
/// Only top-level percent tokens are considered. A conditional token carries its own then/else
/// tokens, which stay under the layout editor's control: a layout whose percent lives inside a
/// conditional reports no single preference, so the picker hides rather than silently rewriting
/// half of it.
enum MenuBarPercentWindowPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case session
    case weekly

    var id: String { self.rawValue }

    var percentWindow: PercentWindow {
        switch self {
        case .automatic: .automatic
        case .session: .session
        case .weekly: .weekly
        }
    }

    var label: String {
        switch self {
        case .automatic: L("menu_bar_layout_token_auto")
        case .session: L("menu_bar_layout_token_session")
        case .weekly: L("menu_bar_layout_token_weekly")
        }
    }

    /// The preference a layout expresses, or nil when its percent tokens mix windows — a
    /// combination only the layout editor can describe, which the picker must not silently flatten.
    static func current(in layout: MenuBarLayout) -> Self? {
        let windows = Self.percentWindows(in: layout)
        guard let first = windows.first, windows.allSatisfy({ $0 == first }) else { return nil }
        return Self.allCases.first { $0.percentWindow == first }
    }

    /// True when the layout shows a percent at all. A layout built from icon-only or reset-time
    /// tokens has nothing for this preference to act on.
    static func hasPercentToken(in layout: MenuBarLayout) -> Bool {
        !Self.percentWindows(in: layout).isEmpty
    }

    /// Layout with every percent token pointed at this preference's window; all other tokens,
    /// including line breaks and separators, are left exactly as the user arranged them.
    func applied(to layout: MenuBarLayout) -> MenuBarLayout {
        MenuBarLayout(lines: layout.lines.map { line in
            line.map { token in
                if case .percent = token {
                    return .percent(window: self.percentWindow)
                }
                return token
            }
        })
    }

    private static func percentWindows(in layout: MenuBarLayout) -> [PercentWindow] {
        layout.lines.flatMap(\.self).compactMap { token in
            guard case let .percent(window) = token else { return nil }
            return window
        }
    }
}
