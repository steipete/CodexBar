import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct CopilotLoginFlow {
    static func run(settings: SettingsStore) async {
        let enterpriseHost = settings.copilotEnterpriseHost
        let flow = CopilotDeviceFlow(enterpriseHost: enterpriseHost.isEmpty ? nil : enterpriseHost)

        do {
            let code = try await flow.requestDeviceCode()

            // Copy code to clipboard
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code.userCode, forType: .string)

            let alert = NSAlert()
            alert.messageText = "GitHub Copilot Login"
            alert.informativeText = """
            A device code has been copied to your clipboard: \(code.userCode)

            Please verify it at: \(code.verificationUri)
            """
            alert.addButton(withTitle: "Open Browser")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return // Cancelled
            }

            if let url = URL(string: code.verificationURLToOpen) {
                NSWorkspace.shared.open(url)
            }

            // Poll in background (modal blocks, but we need to wait for token effectively)
            // Ideally we'd show a "Waiting..." modal or spinner.
            // For simplicity, we can use a non-modal window or just block a Task?
            // `runModal` blocks the thread. We need to poll while the user is doing auth in browser.
            // But we already returned from runModal to open the browser.
            // We need a secondary "Waiting for confirmation..." alert or state.

            // Let's show a "Waiting" alert that can be cancelled.
            let waitingAlert = NSAlert()
            waitingAlert.messageText = "Waiting for Authentication..."
            waitingAlert.informativeText = """
            Please complete the login in your browser.
            This window will close automatically when finished.
            """
            waitingAlert.addButton(withTitle: "Cancel")
            let parentWindow = Self.resolveWaitingParentWindow()
            let hostWindow = parentWindow ?? Self.makeWaitingHostWindow()
            let shouldCloseHostWindow = parentWindow == nil
            let tokenTask = Task.detached(priority: .userInitiated) {
                try await flow.pollForToken(deviceCode: code.deviceCode, interval: code.interval)
            }

            let waitTask = Task { @MainActor in
                let response = await Self.presentWaitingAlert(waitingAlert, parentWindow: hostWindow)
                if response == .alertFirstButtonReturn {
                    tokenTask.cancel()
                }
                return response
            }

            let tokenResult: Result<String, Error>
            do {
                let token = try await tokenTask.value
                tokenResult = .success(token)
            } catch {
                tokenResult = .failure(error)
            }

            Self.dismissWaitingAlert(waitingAlert, parentWindow: hostWindow, closeHost: shouldCloseHostWindow)
            let waitResponse = await waitTask.value
            if waitResponse == .alertFirstButtonReturn {
                return
            }

            switch tokenResult {
            case let .success(token):
                // Fetch username for account label.
                // If accounts already exist, fail closed when identity lookup fails so re-auth cannot create
                // an anonymous duplicate with stale credentials left on the original account.
                let existingAccounts = settings.tokenAccounts(for: .copilot)
                let label: String
                let identity: CopilotUsageFetcher.GitHubUserIdentity?
                do {
                    let resolvedIdentity = try await CopilotUsageFetcher.fetchGitHubIdentity(token: token)
                    let resolvedUsername = resolvedIdentity.login
                    let planSuffix: String
                    do {
                        let fetcher = CopilotUsageFetcher(
                            token: token,
                            enterpriseHost: enterpriseHost.isEmpty ? nil : enterpriseHost)
                        let usage = try await fetcher.fetch()
                        let plan = usage.identity(for: .copilot)?.loginMethod ?? ""
                        planSuffix = plan.isEmpty ? "" : " (\(plan))"
                    } catch {
                        planSuffix = ""
                    }
                    identity = resolvedIdentity
                    label = "\(resolvedUsername)\(planSuffix)"
                } catch {
                    guard existingAccounts.isEmpty else {
                        let err = NSAlert()
                        err.messageText = "Could Not Identify GitHub Account"
                        err.informativeText = "GitHub login succeeded, but CodexBar could not verify which " +
                            "account it belongs to. Please try again."
                        err.runModal()
                        return
                    }
                    identity = nil
                    label = "Account 1"
                }

                // Match existing account by stable GitHub user ID. For legacy accounts that pre-date stable
                // identifiers, also accept login-based externalIdentifier values and resolve stored token identity
                // before falling back to labels.
                let matchedExisting = await Self.matchExistingAccount(
                    existingAccounts: existingAccounts,
                    identity: identity,
                    label: label)
                let externalIdentifier = identity.map(Self.externalIdentifier)
                let wasRefresh = matchedExisting != nil
                if let existing = matchedExisting {
                    settings.updateTokenAccount(
                        provider: .copilot,
                        accountID: existing.id,
                        label: label,
                        token: token,
                        externalIdentifier: .some(externalIdentifier))
                } else {
                    settings.addTokenAccount(
                        provider: .copilot,
                        label: label,
                        token: token,
                        externalIdentifier: externalIdentifier)
                }
                settings.setProviderEnabled(
                    provider: .copilot,
                    metadata: ProviderRegistry.shared.metadata[.copilot]!,
                    enabled: true)

                let success = NSAlert()
                success.messageText = wasRefresh ? "Token Refreshed" : "Account Added"
                success.informativeText = label
                success.runModal()
            case let .failure(error):
                guard !(error is CancellationError) else { return }
                let err = NSAlert()
                err.messageText = "Login Failed"
                err.informativeText = error.localizedDescription
                err.runModal()
            }

        } catch {
            let err = NSAlert()
            err.messageText = "Login Failed"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    static func matchExistingAccount(
        existingAccounts: [ProviderTokenAccount],
        identity: CopilotUsageFetcher.GitHubUserIdentity?,
        label: String,
        legacyIdentityResolver: @escaping @Sendable (ProviderTokenAccount) async
            -> CopilotUsageFetcher.GitHubUserIdentity? = { account in
                try? await CopilotUsageFetcher.fetchGitHubIdentity(token: account.token)
            }) async -> ProviderTokenAccount?
    {
        guard let identity, !existingAccounts.isEmpty else { return nil }
        let stableIdentifier = self.externalIdentifier(for: identity)
        let login = self.normalizedGitHubLogin(identity.login)

        if let byID = existingAccounts.first(where: { account in
            self.normalizedExternalIdentifier(account.externalIdentifier) == stableIdentifier
        }) {
            return byID
        }

        // Previous PR revisions stored GitHub login in externalIdentifier. Keep matching those
        // accounts case-insensitively, then write back the stable ID on update.
        if let byLegacyLogin = existingAccounts.first(where: { account in
            self.normalizedGitHubLogin(account.externalIdentifier) == login
        }) {
            return byLegacyLogin
        }

        let legacyAccounts = existingAccounts.filter { $0.externalIdentifier == nil }
        for account in legacyAccounts {
            guard let resolvedIdentity = await legacyIdentityResolver(account) else { continue }
            if resolvedIdentity.id == identity.id ||
                self.normalizedGitHubLogin(resolvedIdentity.login) == login
            {
                return account
            }
        }

        let usernamePrefix = self.displayLabelPrefix(label)
        return legacyAccounts.first { account in
            self.displayLabelPrefix(account.label) == usernamePrefix
        }
    }

    static func externalIdentifier(for identity: CopilotUsageFetcher.GitHubUserIdentity) -> String {
        "github:user:\(identity.id)"
    }

    private static func normalizedExternalIdentifier(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func normalizedGitHubLogin(_ login: String?) -> String? {
        let trimmed = login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        // Stable IDs are not valid GitHub logins; do not let a numeric-looking login fallback
        // match the "github:user:<id>" identifier path accidentally.
        guard !trimmed.lowercased().hasPrefix("github:user:") else { return nil }
        return trimmed.lowercased()
    }

    private static func displayLabelPrefix(_ label: String) -> String {
        (label.components(separatedBy: " (").first ?? label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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
