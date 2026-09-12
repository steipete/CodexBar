import AppKit
import Testing
@testable import CodexBar

@MainActor
struct PlaceholderSettingsWindowGuardTests {
    @Test
    func `closes the empty SwiftUI Settings placeholder window`() {
        _ = NSApplication.shared
        let placeholder = self.makeWindow(
            identifier: "com_apple_SwiftUI_Settings_window",
            frameAutosaveName: "com_apple_SwiftUI_Settings_window")
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [placeholder] },
            isKnownSettingsWindow: { _ in false },
            closeWindow: { closed.append($0) })

        #expect(guardian.sweep() == 1)
        #expect(closed.count == 1)
        #expect(closed.first === placeholder)
    }

    @Test
    func `keeps the AppKit Settings window and unrelated windows onscreen`() {
        _ = NSApplication.shared
        let settingsWindow = self.makeWindow(identifier: SettingsWindowIdentity.identifier)
        let updateWindow = self.makeWindow(identifier: "SUUpdateAlert")
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [settingsWindow, updateWindow] },
            isKnownSettingsWindow: { $0 === settingsWindow },
            closeWindow: { closed.append($0) })

        #expect(guardian.sweep() == 0)
        #expect(closed.isEmpty)
    }

    @Test
    func `recognizes the placeholder by frame autosave name when the identifier is missing`() {
        #expect(PlaceholderSettingsWindowDecision.shouldClose(
            identifier: nil,
            frameAutosaveName: "com_apple_SwiftUI_Settings_window",
            isKnownSettingsWindow: false))
    }

    @Test
    func `never closes the registered Settings window`() {
        #expect(!PlaceholderSettingsWindowDecision.shouldClose(
            identifier: "com_apple_SwiftUI_Settings_window",
            frameAutosaveName: "com_apple_SwiftUI_Settings_window",
            isKnownSettingsWindow: true))
        #expect(!PlaceholderSettingsWindowDecision.shouldClose(
            identifier: SettingsWindowIdentity.identifier,
            frameAutosaveName: SettingsWindowIdentity.frameAutosaveName,
            isKnownSettingsWindow: false))
    }

    @Test
    func `leaves windows without SwiftUI Settings naming alone`() {
        #expect(!PlaceholderSettingsWindowDecision.shouldClose(
            identifier: nil,
            frameAutosaveName: "",
            isKnownSettingsWindow: false))
    }

    private func makeWindow(identifier: String, frameAutosaveName: String = "") -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        if !frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(frameAutosaveName)
        }
        window.isReleasedWhenClosed = false
        return window
    }
}
