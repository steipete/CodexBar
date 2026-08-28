import AppKit

@MainActor
enum StatusMenuAppearance {
    static func pin(_ menu: NSMenu) {
        self.pin(menu, to: NSApplication.shared.effectiveAppearance)
    }

    static func pin(_ menu: NSMenu, to appearance: NSAppearance) {
        // The exact effective appearance carries accessibility attributes that its name can omit.
        menu.appearance = appearance
    }
}
