import Testing
@testable import CodexBar

struct DockIconPolicyDecisionTests {
    @Test
    func `settings window requires regular activation policy`() {
        let ownedSettings = self.window(identifier: SettingsWindowIdentity.identifier)
        let hostedSettings = self.window(identifier: "future-settings-identifier", isKnownSettingsWindow: true)
        let miniaturizedSettings = self.window(isVisible: false, isMiniaturized: true, isKnownSettingsWindow: true)

        #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [ownedSettings]))
        #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [miniaturizedSettings]))
        #expect(DockIconPolicyDecision.shouldPromoteForPresentedWindow(ownedSettings))
        #expect(DockIconPolicyDecision.shouldPromoteForPresentedWindow(hostedSettings))
    }

    @Test
    func `launch placeholder never promotes or retains regular policy`() {
        // On macOS 27, promotion can succeed while the getter still reports accessory and demotion fails.
        // Avoid that transition even when the placeholder is visible before the launch sweep closes it.
        for (visible, miniaturized) in [(true, false), (false, false), (false, true)] {
            let placeholder = self.window(
                identifier: "com_apple_SwiftUI_Settings_window",
                isVisible: visible,
                isMiniaturized: miniaturized)
            #expect(!DockIconPolicyDecision.shouldPromoteForPresentedWindow(placeholder))
            #expect(!DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [placeholder]))
        }
    }

    @Test
    func `autosave-only placeholders cannot retain the Dock after a real dialog closes`() {
        let placeholder = self.window(frameAutosaveName: "com_apple_SwiftUI_Settings_window")
        let settings = self.window(isVisible: false, isKnownSettingsWindow: true)
        #expect(!DockIconPolicyDecision.shouldPromoteForPresentedWindow(placeholder))
        #expect(!DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [placeholder, settings]))
    }

    @Test
    func `registered Settings identity overrides placeholder naming`() {
        for window in [
            self.window(identifier: "com_apple_SwiftUI_Settings_window", isKnownSettingsWindow: true),
            self.window(
                identifier: SettingsWindowIdentity.identifier,
                frameAutosaveName: "com_apple_SwiftUI_Settings_window"),
        ] {
            #expect(DockIconPolicyDecision.shouldPromoteForPresentedWindow(window))
            #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [window]))
        }
    }

    @Test
    func `presentation attempt waits resolves or times out deterministically`() {
        var tracker = DockIconPresentationAttemptTracker()
        #expect(tracker.resolve(hasPresentedWindow: false, deadlineExpiredFor: nil) == .inactive)
        _ = tracker.begin()
        #expect(tracker.resolve(hasPresentedWindow: false, deadlineExpiredFor: nil) == .awaiting)
        #expect(tracker.resolve(hasPresentedWindow: true, deadlineExpiredFor: nil) == .presented)
        #expect(!tracker.isAwaiting)
        let attempt = tracker.begin()
        #expect(tracker.resolve(hasPresentedWindow: false, deadlineExpiredFor: attempt) == .timedOut)
        #expect(!tracker.isAwaiting)
    }

    @Test
    func `presentation attempt completion only resolves its own generation`() {
        var tracker = DockIconPresentationAttemptTracker()
        let first = tracker.begin()
        let second = tracker.begin()

        let staleFinished = tracker.finish(first)
        #expect(!staleFinished)
        #expect(tracker.isAwaiting)
        let activeFinished = tracker.finish(second)
        #expect(activeFinished)
        #expect(!tracker.isAwaiting)
    }

    @Test
    func `presentation attempt watchdog ignores stale deadlines and resolves the active deadline`() {
        var tracker = DockIconPresentationAttemptTracker()
        let stale = tracker.begin()
        let active = tracker.begin()

        let staleDecision = tracker.resolve(
            hasPresentedWindow: false,
            deadlineExpiredFor: stale)
        #expect(staleDecision == .awaiting)
        #expect(tracker.isAwaiting)
        let activeDecision = tracker.resolve(
            hasPresentedWindow: false,
            deadlineExpiredFor: active)
        #expect(activeDecision == .timedOut)
        #expect(!tracker.isAwaiting)
    }

    @Test
    func `Sparkle window requires regular activation policy`() {
        let sparkle = self.window(
            title: "A new version is available",
            classNames: ["Sparkle.SPUStandardUserDriverWindowController"])

        #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [sparkle]))
        #expect(DockIconPolicyDecision.shouldPromoteForPresentedWindow(sparkle))
    }

    @Test
    func `another real window keeps regular activation policy after settings closes`() {
        let closedSettings = self.window(
            isVisible: false,
            isKnownSettingsWindow: true)
        let updateWindow = self.window(
            title: "Update Ready",
            classNames: ["SPUUpdateAlert"])
        let otherWindow = self.window(title: "Share Usage")

        #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [closedSettings, updateWindow]))
        #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [closedSettings, otherWindow]))
    }

    @Test
    func `status bar and non-key windows allow accessory activation policy`() {
        let statusBar = self.window(
            classNames: ["NSStatusBarWindow"],
            width: 300,
            height: 30)
        let borderlessPanel = self.window(
            classNames: ["NSPanel"],
            canBecomeKey: false)

        #expect(!DockIconPolicyDecision.shouldUseRegularActivationPolicy(
            windows: [statusBar, borderlessPanel]))
    }

    @Test
    func `hidden miniaturized and tiny windows allow accessory activation policy`() {
        let hidden = self.window(isVisible: false)
        let miniaturized = self.window(isMiniaturized: true)
        let tiny = self.window(width: 20, height: 20)

        #expect(!DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [hidden, miniaturized, tiny]))
    }

    @Test
    func `newly presented window IDs exclude already tracked dialogs`() {
        final class Token {}
        let settingsToken = Token()
        let sparkleToken = Token()
        let settingsID = ObjectIdentifier(settingsToken)
        let sparkleID = ObjectIdentifier(sparkleToken)
        let previous: Set<ObjectIdentifier> = [settingsID]
        let current: Set<ObjectIdentifier> = [settingsID, sparkleID]

        let newlyPresented = DockIconPolicyDecision.newlyPresentedWindowIDs(
            current: current,
            previous: previous)

        #expect(newlyPresented == [sparkleID])
        #expect(!newlyPresented.contains(settingsID))
        _ = (settingsToken, sparkleToken)
    }

    private func window(
        identifier: String? = nil,
        frameAutosaveName: String = "",
        title: String = "Window",
        classNames: [String] = ["NSWindow"],
        width: Double = 600,
        height: Double = 400,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        canBecomeKey: Bool = true,
        isKnownSettingsWindow: Bool = false)
        -> DockIconWindowDescriptor
    {
        DockIconWindowDescriptor(
            identifier: identifier,
            frameAutosaveName: frameAutosaveName,
            title: title,
            classNames: classNames,
            width: width,
            height: height,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            canBecomeKey: canBecomeKey,
            isKnownSettingsWindow: isKnownSettingsWindow)
    }
}
