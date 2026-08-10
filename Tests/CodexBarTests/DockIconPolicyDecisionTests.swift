import Testing
@testable import CodexBar

struct DockIconPolicyDecisionTests {
    @Test
    func `settings window requires regular activation policy`() {
        let settings = self.window(identifier: "com_apple_SwiftUI_Settings_window")
        let hostedSettings = self.window(identifier: "future-settings-identifier", isKnownSettingsWindow: true)

        #expect(DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [settings]))
        #expect(DockIconPolicyDecision.shouldPromoteForPresentedWindow(settings))
        #expect(DockIconPolicyDecision.shouldPromoteForPresentedWindow(hostedSettings))
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
    func `ignored windows allow accessory activation policy`() {
        let keepalive = self.window(
            identifier: "CodexBarLifecycleKeepalive",
            title: "CodexBarLifecycleKeepalive",
            width: 1,
            height: 1,
            canBecomeKey: false)
        let statusBar = self.window(
            classNames: ["NSStatusBarWindow"],
            width: 300,
            height: 30)
        let borderlessPanel = self.window(
            classNames: ["NSPanel"],
            canBecomeKey: false)

        #expect(!DockIconPolicyDecision.shouldUseRegularActivationPolicy(
            windows: [keepalive, statusBar, borderlessPanel]))
    }

    @Test
    func `hidden miniaturized and tiny windows allow accessory activation policy`() {
        let hidden = self.window(isVisible: false)
        let miniaturized = self.window(isMiniaturized: true)
        let tiny = self.window(width: 20, height: 20)

        #expect(!DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: [hidden, miniaturized, tiny]))
    }

    private func window(
        identifier: String? = nil,
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
