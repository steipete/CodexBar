import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SettingsWindowLifetimeTests {
    @Test
    func `closing Settings releases its preview and preserves navigation and frame`() throws {
        _ = NSApplication.shared
        let selection = PreferencesSelection(userDefaults: InMemoryUserDefaults())
        weak var preview: NSViewController?
        weak var previewView: NSView?
        let controller = SettingsWindowController(
            selection: selection,
            makeWindow: {
                let window = NSWindow(
                    contentRect: NSRect(x: 100, y: 100, width: 880, height: 620),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: Text("Synthetic Settings"))
                return window
            },
            prepareToPresent: {},
            registerWindow: { _ in },
            presentWindow: { _ in },
            didPresentWindow: { _ in },
            presentationFailed: {})
        defer { controller.close() }
        let frame = NSRect(x: 200, y: 200, width: 1000, height: 800)
        try autoreleasepool {
            controller.open(pane: .about)
            selection.showAcknowledgements()
            let window = try #require(controller.window)
            window.setFrame(frame, display: false)
            let installedPreview: NSViewController = try #require(window.contentViewController)
            preview = installedPreview
            previewView = preview?.view
            controller.close()
        }
        let retainsPreview = preview != nil
        let retainsPreviewView = previewView != nil
        #expect(!retainsPreview)
        #expect(!retainsPreviewView)
        controller.open(pane: nil)
        #expect(controller.window?.contentViewController != nil)
        #expect(controller.window?.frame == frame)
        #expect(selection.pane == .about)
        #expect(selection.destination.aboutRoute == .acknowledgements)
    }
}
