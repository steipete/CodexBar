#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// Opens the real manual panel before normal settings, providers, or shared cost caches start.
@MainActor
enum UsageLedgerNativePreview {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--usage-ledger-preview")
            || ProcessInfo.processInfo.environment["CODEXBAR_USAGE_LEDGER_PREVIEW"] == "1"
        else { return false }
        configureUsageFormatterLocalizationProvider()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private var window: NSWindow?

        func applicationDidFinishLaunching(_ notification: Notification) {
            let app = NSApplication.shared
            let menu = NSMenu()
            let applicationItem = NSMenuItem()
            let applicationMenu = NSMenu()
            let quit = NSMenuItem(
                title: L("quit_app"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = app
            applicationMenu.addItem(quit)
            applicationItem.submenu = applicationMenu
            menu.addItem(applicationItem)
            app.mainMenu = menu

            let content = ScrollView {
                CrossHostUsagePanel(calendar: .current)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = L("Cross-host usage — Experimental")
            window.minSize = NSSize(width: 600, height: 360)
            window.contentView = NSHostingView(rootView: content)
            window.isReleasedWhenClosed = false
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }
}
#endif
