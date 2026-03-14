import AppKit
import SwiftUI

struct HiddenWindowView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 20, height: 20)
            .onReceive(NotificationCenter.default.publisher(for: .codexbarOpenSettings)) { _ in
                Task { @MainActor in
                    self.openSettings()
                    // Menu-bar apps don't automatically own keyboard focus.
                    // Force the Settings window to become key so text fields
                    // receive keystrokes instead of the previously-active app.
                    Self.forceSettingsWindowKey()
                }
            }
            .task {
                // Migrate keychain items to reduce permission prompts during development (runs off main thread)
                await Task.detached(priority: .userInitiated) {
                    KeychainMigration.migrateIfNeeded()
                }.value
            }
            // When the last key-capable window closes, revert to menu-bar-only
            // so the app disappears from the Dock and Cmd-Tab switcher.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard let window = note.object as? NSWindow,
                      window.canBecomeKey,
                      window.title != "CodexBarLifecycleKeepalive"
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { @MainActor in
                    let hasVisibleKeyWindow = NSApp.windows.contains {
                        $0.isVisible && $0.canBecomeKey && $0.title != "CodexBarLifecycleKeepalive"
                    }
                    if !hasVisibleKeyWindow {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
            .onAppear {
                if let window = NSApp.windows.first(where: { $0.title == "CodexBarLifecycleKeepalive" }) {
                    // Make the keepalive window truly invisible and non-interactive.
                    window.styleMask = [.borderless]
                    window.collectionBehavior = [.auxiliary, .ignoresCycle, .transient, .canJoinAllSpaces]
                    window.isExcludedFromWindowsMenu = true
                    window.level = .floating
                    window.isOpaque = false
                    window.alphaValue = 0
                    window.backgroundColor = .clear
                    window.hasShadow = false
                    window.ignoresMouseEvents = true
                    window.canHide = false
                    window.setContentSize(NSSize(width: 1, height: 1))
                    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                }
            }
    }

    @MainActor
    private static func forceSettingsWindowKey() {
        NSApp.setActivationPolicy(.regular)
        // Retry activation several times with increasing delays.
        // The SwiftUI Settings window is created asynchronously and may not
        // exist on the first attempt; the activation policy change also needs
        // a run-loop cycle to take effect before the app can receive focus.
        for delay in [0.05, 0.15, 0.3, 0.5, 0.8] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { @MainActor in
                Self.activateAndFocusSettingsWindow()
            }
        }
    }

    @MainActor
    private static func activateAndFocusSettingsWindow() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        for window in NSApp.windows where window.isVisible && window.canBecomeKey
            && window.title != "CodexBarLifecycleKeepalive"
        {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
