import Foundation

/// How the notch overlay shortcut behaves.
enum NotchHotkeyMode: String, CaseIterable, Sendable {
    /// Press once to show, press again to hide.
    case toggle
    /// Visible only while the shortcut is held down.
    case hold

    var label: String {
        switch self {
        case .toggle: L("notch_hotkey_mode_toggle")
        case .hold: L("notch_hotkey_mode_hold")
        }
    }
}

/// Pure decision table for the overlay shortcut, so hold/toggle semantics are testable without
/// AppKit windows or a registered global hotkey.
enum NotchHotkeyDecision: Equatable {
    case expand
    case collapse
    case ignore
}

struct NotchHotkeyState: Equatable {
    /// True while the shortcut owns the panel, so losing the pointer must not collapse it.
    private(set) var isHolding = false

    mutating func press(mode: NotchHotkeyMode, isExpanded: Bool) -> NotchHotkeyDecision {
        if mode == .toggle, isExpanded {
            self.isHolding = false
            return .collapse
        }
        self.isHolding = true
        return .expand
    }

    mutating func release(mode: NotchHotkeyMode, isPointerInside: Bool) -> NotchHotkeyDecision {
        guard mode == .hold, self.isHolding else { return .ignore }
        self.isHolding = false
        // Releasing over the panel hands control back to hover instead of closing under the cursor.
        return isPointerInside ? .ignore : .collapse
    }

    mutating func clear() {
        self.isHolding = false
    }
}
