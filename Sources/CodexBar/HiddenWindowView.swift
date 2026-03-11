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
            // Also catch when the Settings window first appears (e.g. opened via
            // the SwiftUI lifecycle rather than the notification path).
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { note in
                guard let window = note.object as? NSWindow,
                      window.canBecomeKey,
                      window.title != "CodexBarLifecycleKeepalive"
                else { return }
                Task { @MainActor in
                    Self.forceSettingsWindowKey()
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
        NSApp.activate(ignoringOtherApps: true)
        // Give the window a moment to appear, then make it key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { @MainActor in
            for window in NSApp.windows where window.isVisible && window.canBecomeKey
                && window.title != "CodexBarLifecycleKeepalive"
            {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}
