import AppKit
import CodexBarCore

@MainActor
struct AntigravityLoginFlow {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    static func runOAuthFlow(settings: SettingsStore, store: UsageStore? = nil) async -> Bool {
        self.log.debug("Starting Antigravity OAuth login flow")
        self.log.debug("Keychain access disabled: \(KeychainAccessGate.isDisabled)")

        let flow = AntigravityOAuthFlow()

        let waitingAlert = NSAlert()
        waitingAlert.messageText = "Waiting for Authentication..."
        waitingAlert.informativeText = """
        Please complete the sign-in in your browser.
        This window will close automatically when finished.
        """
        waitingAlert.addButton(withTitle: "Cancel")
        let parentWindow = Self.resolveWaitingParentWindow()
        let hostWindow = parentWindow ?? Self.makeWaitingHostWindow()
        let shouldCloseHostWindow = parentWindow == nil

        let waitTask = Task { @MainActor in
            let response = await Self.presentWaitingAlert(waitingAlert, parentWindow: hostWindow)
            if response == .alertFirstButtonReturn {
                await flow.cancelAuthorization()
            }
            return response
        }
        await Task.yield()

        let authTask = Task.detached(priority: .userInitiated) {
            try await flow.startAuthorization()
        }

        let authResult: Result<AntigravityOAuthCredentials, Error>
        do {
            let credentials = try await authTask.value
            authResult = .success(credentials)
        } catch {
            authResult = .failure(error)
        }

        Self.dismissWaitingAlert(waitingAlert, parentWindow: hostWindow, closeHost: shouldCloseHostWindow)
        let waitResponse = await waitTask.value
        if waitResponse == .alertFirstButtonReturn {
            return false
        }

        switch authResult {
        case let .success(credentials):
            guard let accountLabel = Self.persistCredentials(credentials, settings: settings) else {
                Self.presentAlert(title: "Authorization Failed", message: "Unable to store Antigravity credentials.")
                return false
            }
            if let store {
                await store.refreshProvider(.antigravity, allowDisabled: true)
            }

            let success = NSAlert()
            success.messageText = "Authorization Successful"
            success.informativeText = "Signed in as \(accountLabel)."
            success.runModal()
            return true
        case let .failure(error):
            guard !(error is CancellationError) else { return false }
            Self.presentAlert(title: "Authorization Failed", message: error.localizedDescription)
            return false
        }
    }

    private static func persistCredentials(
        _ credentials: AntigravityOAuthCredentials,
        settings: SettingsStore) -> String?
    {
        guard let accountLabel = resolveAccountLabel(credentials: credentials, settings: settings) else {
            self.log.debug("Failed to resolve account label")
            return nil
        }
        Self.log.debug("Persisting credentials for account: \(accountLabel)")

        if !KeychainAccessGate.isDisabled {
            guard AntigravityOAuthCredentialsStore.save(credentials, accountLabel: accountLabel) else {
                Self.log.debug("Failed to save credentials to Keychain")
                return nil
            }
            Self.log.debug("Saved credentials to Keychain")
            _ = settings.upsertAntigravityTokenAccount(label: accountLabel)
        } else {
            Self.log.debug("Keychain disabled, storing tokens in config")
            guard settings.addManualAntigravityTokenAccount(
                label: accountLabel,
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken) != nil
            else {
                Self.log.debug("Failed to save credentials to config")
                return nil
            }
        }

        settings.setProviderEnabled(
            provider: .antigravity,
            metadata: ProviderRegistry.shared.metadata[.antigravity]!,
            enabled: true)
        Self.log.debug("Provider enabled and token account created")
        return accountLabel
    }

    private static func resolveAccountLabel(
        credentials: AntigravityOAuthCredentials,
        settings: SettingsStore) -> String?
    {
        if let email = credentials.email,
           let normalized = AntigravityOAuthCredentialsStore.normalizedLabel(email)
        {
            return normalized
        }

        let existingLabels = Set(settings.tokenAccounts(for: .antigravity).map { $0.label.lowercased() })
        var index = 1
        while existingLabels.contains("account \(index)") {
            index += 1
        }
        return "account \(index)"
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @MainActor
    private static func presentWaitingAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow) async -> NSApplication.ModalResponse
    {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parentWindow) { response in
                continuation.resume(returning: response)
            }
        }
    }

    @MainActor
    private static func dismissWaitingAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow,
        closeHost: Bool)
    {
        let alertWindow = alert.window
        if alertWindow.sheetParent != nil {
            parentWindow.endSheet(alertWindow)
        } else {
            alertWindow.orderOut(nil)
        }

        guard closeHost else { return }
        parentWindow.orderOut(nil)
        parentWindow.close()
    }

    @MainActor
    private static func resolveWaitingParentWindow() -> NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return window
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && !$0.ignoresMouseEvents }) {
            return window
        }
        return NSApp.windows.first
    }

    @MainActor
    private static func makeWaitingHostWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async -> Bool {
        self.loginPhase = .waitingBrowser
        let success = await AntigravityLoginFlow.runOAuthFlow(settings: self.settings)
        self.loginPhase = .idle
        if success {
            self.postLoginNotification(for: .antigravity)
        }
        return success
    }
}
