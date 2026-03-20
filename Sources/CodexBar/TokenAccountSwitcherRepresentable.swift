import AppKit
import CodexBarCore
import SwiftUI

/// Hosts the same `TokenAccountSwitcherView` used in the menu bar so Codex settings can mirror that UX.
@MainActor
struct TokenAccountSwitcherRepresentable: NSViewRepresentable {
    let accounts: [ProviderTokenAccount]
    let defaultAccountLabel: String?
    let selectedIndex: Int
    let width: CGFloat
    let onSelect: (Int) -> Void

    func makeNSView(context _: Context) -> TokenAccountSwitcherView {
        TokenAccountSwitcherView(
            accounts: self.accounts,
            defaultAccountLabel: self.defaultAccountLabel,
            selectedIndex: self.selectedIndex,
            width: self.width,
            contentMargin: 0,
            onSelect: self.onSelect)
    }

    func updateNSView(_: TokenAccountSwitcherView, context _: Context) {
        // Selection and accounts are refreshed via `.id(...)` from the parent when settings change.
    }
}
