import AppKit
import Testing
@testable import CodexBar

@MainActor
struct SettingsWindowOpeningTests {
    @Test
    func `recreated keepalive shell is configured and missing relay invokes settings fallback`() {
        let keepaliveShell = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let configuratorView = KeepaliveWindowConfiguratorView(windowProvider: { _ in keepaliveShell })
        configuratorView.viewDidMoveToWindow()

        #expect(keepaliveShell.identifier?.rawValue == "CodexBarLifecycleKeepalive")
        #expect(keepaliveShell.styleMask == [.borderless])
        #expect(keepaliveShell.alphaValue == 0)
        #expect(keepaliveShell.frame.size == NSSize(width: 1, height: 1))

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        var presentedWindow: NSWindow?
        let opener = SettingsWindowOpener(
            notification: { false },
            appKit: {
                presentedWindow = settingsWindow
                return true
            })

        let outcome = opener.open(preferred: .notification)

        #expect(outcome == .fallback)
        #expect(presentedWindow === settingsWindow)
    }
}
