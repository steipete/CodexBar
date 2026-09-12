import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct CopilotLoginFlow {
    static func run(settings: SettingsStore) async {
        let revision = settings.providerConfigRevision(for: .copilot)
        let enterpriseHost = settings.copilotEnterpriseHost
        let issuer = CopilotUsageFetcher.apiHost(enterpriseHost: enterpriseHost)
        let flow = CopilotDeviceFlow(enterpriseHost: enterpriseHost)

        do {
            let code = try await flow.requestDeviceCode()

            // Copy code to clipboard
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code.userCode, forType: .string)

            let alert = NSAlert()
            alert.messageText = L("GitHub Copilot Login")
            alert.informativeText = String(format: L("copilot_device_code"), code.userCode, code.verificationUri)
            alert.addButton(withTitle: L("Open Browser"))
            alert.addButton(withTitle: L("Cancel"))

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
            waitingAlert.messageText = L("Waiting for Authentication...")
            waitingAlert.informativeText = L("copilot_waiting_text")
            waitingAlert.addButton(withTitle: L("Cancel"))
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

            let tokenResult = await tokenTask.result

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
                let label: String
                let identity: CopilotUsageFetcher.GitHubUserIdentity?
                do {
                    let resolvedIdentity = try await CopilotUsageFetcher.fetchGitHubIdentity(
                        token: token, enterpriseHost: enterpriseHost)
                    let usage = try? await CopilotUsageFetcher(token: token, enterpriseHost: enterpriseHost).fetch()
                    let plan = usage?.identity(for: .copilot)?.loginMethod ?? ""
                    identity = resolvedIdentity
                    label = plan.isEmpty ? resolvedIdentity.login : "\(resolvedIdentity.login) (\(plan))"
                } catch {
                    guard settings.tokenAccounts(for: .copilot).isEmpty, issuer == "api.github.com" else {
                        let err = NSAlert()
                        err.messageText = L("Could Not Identify GitHub Account")
                        err.informativeText = L(
                            "GitHub login succeeded, but CodexBar could not verify which " +
                                "account it belongs to. Please try again.")
                        err.runModal()
                        return
                    }
                    identity = nil
                    label = "Account 1"
                }

                guard let wasRefresh = await Self.storeLoginIfCurrent(
                    settings: settings, revision: revision, token: token, identity: identity, label: label)
                else { return }

                let success = NSAlert()
                success.messageText = wasRefresh ? L("Token Refreshed") : L("Account Added")
                success.informativeText = label
                success.runModal()
            case let .failure(error):
                guard !(error is CancellationError) else { return }
                throw error
            }

        } catch {
            let err = NSAlert()
            err.messageText = L("Login Failed")
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    static func storeLoginIfCurrent(
        settings: SettingsStore,
        revision: UInt64,
        token: String,
        identity: CopilotUsageFetcher.GitHubUserIdentity?,
        label: String,
        legacyIdentityResolver: @escaping @Sendable (ProviderTokenAccount) async
            -> CopilotUsageFetcher.GitHubUserIdentity? = { account in
                try? await CopilotUsageFetcher.fetchGitHubIdentity(token: account.token)
            }) async -> Bool?
    {
        guard settings.providerConfigRevision(for: .copilot) == revision else { return nil }
        let issuer = CopilotUsageFetcher.apiHost(enterpriseHost: settings.copilotEnterpriseHost)
        let matchedExisting = await Self.matchExistingAccount(
            existingAccounts: settings.tokenAccounts(for: .copilot),
            identity: identity,
            label: label,
            issuer: issuer,
            legacyIdentityResolver: legacyIdentityResolver)
        guard !Task.isCancelled,
              settings.providerConfigRevision(for: .copilot) == revision,
              identity != nil || issuer == "api.github.com" && settings.tokenAccounts(for: .copilot).isEmpty
        else { return nil }
        let externalIdentifier = identity.map { Self.externalIdentifier(for: $0, issuer: issuer) }
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

        return matchedExisting != nil
    }

    static func matchExistingAccount(
        existingAccounts: [ProviderTokenAccount],
        identity: CopilotUsageFetcher.GitHubUserIdentity?,
        label: String,
        issuer: String = "api.github.com",
        legacyIdentityResolver: @escaping @Sendable (ProviderTokenAccount) async
            -> CopilotUsageFetcher.GitHubUserIdentity? = { account in
                try? await CopilotUsageFetcher.fetchGitHubIdentity(token: account.token)
            }) async -> ProviderTokenAccount?
    {
        guard let identity, !existingAccounts.isEmpty else { return nil }
        let stableIdentifier = self.externalIdentifier(for: identity, issuer: issuer)
        let login = self.normalizedGitHubLogin(identity.login)

        if let byID = existingAccounts.first(where: { account in
            self.normalizedExternalIdentifier(account.externalIdentifier) == stableIdentifier
        }) {
            return byID
        }

        // Hostless legacy identifiers belong to the existing public-GitHub path.
        guard issuer == "api.github.com" else { return nil }

        // Previous PR revisions stored GitHub login in externalIdentifier. Keep matching those
        // accounts case-insensitively, then write back the stable ID on update.
        if let byLegacyLogin = existingAccounts.first(where: { account in
            self.normalizedGitHubLogin(account.externalIdentifier) == login
        }) {
            return byLegacyLogin
        }

        var labelFallback: ProviderTokenAccount?
        for account in existingAccounts where account.externalIdentifier == nil {
            if let resolvedIdentity = await legacyIdentityResolver(account) {
                if resolvedIdentity.id == identity.id {
                    return account
                }
            } else if labelFallback == nil,
                      self.displayLabelPrefix(account.label) == self.displayLabelPrefix(label)
            {
                labelFallback = account
            }
        }
        return labelFallback
    }

    static func externalIdentifier(
        for identity: CopilotUsageFetcher.GitHubUserIdentity,
        issuer: String = "api.github.com") -> String
    {
        issuer == "api.github.com" ? "github:user:\(identity.id)" : "github:\(issuer):user:\(identity.id)"
    }

    private static func normalizedExternalIdentifier(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func normalizedGitHubLogin(_ login: String?) -> String? {
        guard let normalized = self.normalizedExternalIdentifier(login), !normalized.hasPrefix("github:")
        else { return nil }
        return normalized
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
