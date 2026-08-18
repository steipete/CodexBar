import AppKit
import Testing
@testable import CodexBar

@MainActor
struct SettingsWindowControllerTests {
    @Test
    func `creates registers and presents an identified Settings window`() {
        _ = NSApplication.shared
        let selection = self.makeSelection(suffix: "create")
        let window = self.makeWindow()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        var events: [String] = []
        let controller = SettingsWindowController(
            selection: selection,
            makeWindow: {
                events.append("make")
                return window
            },
            prepareToPresent: { events.append("prepare") },
            registerWindow: { registeredWindow in
                #expect(registeredWindow === window)
                #expect(registeredWindow.identifier?.rawValue == SettingsWindowIdentity.identifier)
                events.append("register")
            },
            presentWindow: { presentedWindow in
                #expect(presentedWindow === window)
                events.append("present")
            },
            didPresentWindow: { presentedWindow in
                #expect(presentedWindow === window)
                events.append("did-present")
            },
            presentationFailed: { events.append("failed") })

        let outcome = controller.open(pane: .about)

        #expect(outcome == .created)
        #expect(selection.pane == .about)
        #expect(window.collectionBehavior == SettingsWindowStageBehavior.collectionBehavior)
        #expect(events == ["prepare", "make", "register", "present", "did-present"])
    }

    @Test
    func `reuses the window and switches panes while it remains open`() {
        _ = NSApplication.shared
        let selection = self.makeSelection(suffix: "reuse")
        let window = self.makeWindow()
        var makeCount = 0
        var registeredWindows: [NSWindow] = []
        var presentedPanes: [SettingsPane] = []
        let controller = SettingsWindowController(
            selection: selection,
            makeWindow: {
                makeCount += 1
                return window
            },
            prepareToPresent: {},
            registerWindow: { registeredWindows.append($0) },
            presentWindow: { _ in presentedPanes.append(selection.pane) },
            didPresentWindow: { _ in },
            presentationFailed: {})

        let firstOutcome = controller.open(pane: .about)
        let secondOutcome = controller.open(pane: .general)

        #expect(firstOutcome == .created)
        #expect(secondOutcome == .reused)
        #expect(makeCount == 1)
        #expect(registeredWindows.count == 2)
        #expect(registeredWindows.allSatisfy { $0 === window })
        #expect(presentedPanes == [.about, .general])
        #expect(selection.pane == .general)
    }

    @Test
    func `window creation failure resolves the presentation attempt`() {
        let selection = self.makeSelection(suffix: "failure")
        var events: [String] = []
        let controller = SettingsWindowController(
            selection: selection,
            makeWindow: {
                events.append("make")
                return nil
            },
            prepareToPresent: { events.append("prepare") },
            registerWindow: { _ in events.append("register") },
            presentWindow: { _ in events.append("present") },
            didPresentWindow: { _ in events.append("did-present") },
            presentationFailed: { events.append("failed") })

        let outcome = controller.open(pane: nil)

        #expect(outcome == .failed)
        #expect(events == ["prepare", "make", "failed"])
    }

    private func makeSelection(suffix: String) -> PreferencesSelection {
        let suiteName = "SettingsWindowControllerTests-\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PreferencesSelection(userDefaults: defaults)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
    }
}
