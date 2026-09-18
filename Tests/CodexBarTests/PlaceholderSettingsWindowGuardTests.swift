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
    func `closes a retained placeholder only once across repeated sweeps`() {
        _ = NSApplication.shared
        let placeholder = self.makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [placeholder] },
            closeWindow: { closed.append($0) })

        #expect(guardian.sweep() == 1)
        for _ in 0..<3 {
            #expect(guardian.sweep() == 0)
        }
        #expect(closed.count == 1)
        #expect(closed.first === placeholder)
    }

    @Test
    func `does not close a placeholder again when closing posts an update notification`() {
        _ = NSApplication.shared
        let placeholder = self.makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [placeholder] },
            closeWindow: {
                closed.append($0)
                if closed.count == 1 {
                    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: $0)
                }
            })

        guardian.start()
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: placeholder)

        #expect(closed.count == 1)
        #expect(closed.first === placeholder)
    }

    @Test
    func `closes the same retained placeholder after it is presented again`() {
        _ = NSApplication.shared
        let placeholder = self.makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        var isVisible = true
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [placeholder] },
            isVisible: { _ in isVisible },
            closeWindow: {
                closed.append($0)
                if closed.count <= 2 {
                    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: $0)
                }
                isVisible = false
            })

        guardian.start()
        #expect(closed.count == 1)
        #expect(guardian.sweep() == 0)

        isVisible = true
        #expect(guardian.sweep() == 1)
        #expect(closed.count == 2)
        #expect(closed.allSatisfy { $0 === placeholder })
        #expect(guardian.sweep() == 0)
    }

    @Test
    func `still closes new placeholders and windows that become placeholders later`() {
        _ = NSApplication.shared
        let placeholder = self.makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        let laterPlaceholder = self.makeWindow(identifier: "unrelated")
        let state = PlaceholderWindowCollection([placeholder, laterPlaceholder])
        var closed: [NSWindow] = []
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { state.windows },
            closeWindow: { closed.append($0) })

        #expect(guardian.sweep() == 1)
        let newPlaceholder = self.makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        state.windows.append(newPlaceholder)
        laterPlaceholder.identifier = placeholder.identifier

        #expect(guardian.sweep() == 2)
        #expect(closed.count == 3)
        #expect(closed.contains { $0 === laterPlaceholder })
        #expect(closed.contains { $0 === newPlaceholder })
        #expect(guardian.sweep() == 0)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_SETTINGS_CLOSE_NATIVE_PROOF"] == "1"))
    func `native close notifications settle and a retained window can be dismissed again`() {
        _ = NSApplication.shared
        let placeholder = PlaceholderCloseCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        placeholder.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        placeholder.isReleasedWhenClosed = false
        let settings = self.makeWindow(identifier: SettingsWindowIdentity.identifier)
        let unrelated = self.makeWindow(identifier: "synthetic-update-window")
        defer {
            placeholder.orderOut(nil)
            settings.close()
            unrelated.close()
        }
        let guardian = PlaceholderSettingsWindowGuard(
            windows: { [placeholder, settings, unrelated] },
            isKnownSettingsWindow: { $0 === settings })
        guardian.start()
        for _ in 0..<100 {
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: placeholder)
        }
        let settledCloseCount = placeholder.closeCount
        #expect(settledCloseCount == 1)
        #expect(!placeholder.isVisible)

        placeholder.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: placeholder)
        let representedCloseCount = placeholder.closeCount
        #expect(representedCloseCount == 2)
        #expect(!placeholder.isVisible)
        #expect(guardian.sweep() == 0)
        #expect(settings.closeCount == 0)
        #expect(unrelated.closeCount == 0)
        print("Native Settings proof: after 100 updates=\(settledCloseCount), "
            + "after re-presentation=\(representedCloseCount), visible=\(placeholder.isVisible)")
    }

    private func makeWindow(
        identifier: String,
        frameAutosaveName: String = "") -> PlaceholderCloseCountingWindow
    {
        let window = PlaceholderCloseCountingWindow(
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

@MainActor
private final class PlaceholderWindowCollection {
    var windows: [NSWindow]

    init(_ windows: [NSWindow]) {
        self.windows = windows
    }
}

@MainActor
private final class PlaceholderCloseCountingWindow: NSWindow {
    private(set) var closeCount = 0

    override func close() {
        self.closeCount += 1
        // Exercise a synchronous notification during a real AppKit close, bounded on the old implementation.
        if self.closeCount == 1 {
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: self)
        }
        super.close()
    }
}
