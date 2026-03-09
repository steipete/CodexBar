import AppKit
import CodexBarCore

extension StatusItemController {
    // MARK: - Actions reachable from menus

    func refreshStore(forceTokenUsage: Bool) {
        Task {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refresh(forceTokenUsage: forceTokenUsage)
            }
        }
    }

    @objc func refreshNow() {
        self.refreshStore(forceTokenUsage: true)
    }

    @objc func refreshAugmentSession() {
        Task {
            await self.store.forceRefreshAugmentSession()
            // Also trigger a full refresh to update the menu and clear any stale errors
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refresh(forceTokenUsage: false)
            }
        }
    }

    @objc func installUpdate() {
        self.updater.checkForUpdates(nil)
    }

    @objc func openDashboard() {
        let preferred = self.lastMenuProvider
            ?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledProviders().first)

        let provider = preferred ?? .codex
        let meta = self.store.metadata(for: provider)

        // For Claude, route subscription users to claude.ai/settings/usage instead of console billing
        let urlString: String? = if provider == .claude, self.store.isClaudeSubscription() {
            meta.subscriptionDashboardURL ?? meta.dashboardURL
        } else {
            meta.dashboardURL
        }

        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openCreditsPurchase() {
        let preferred = self.lastMenuProvider
            ?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledProviders().first)
        let provider = preferred ?? .codex
        guard provider == .codex else { return }

        let dashboardURL = self.store.metadata(for: .codex).dashboardURL
        let purchaseURL = Self.sanitizedCreditsPurchaseURL(self.store.openAIDashboard?.creditsPurchaseURL)
        let urlString = purchaseURL ?? dashboardURL
        guard let urlString,
              let url = URL(string: urlString) else { return }

        let autoStart = true
        let accountEmail = self.store.codexAccountEmailForOpenAIDashboard()
        let controller = self.creditsPurchaseWindow ?? OpenAICreditsPurchaseWindowController()
        controller.show(purchaseURL: url, accountEmail: accountEmail, autoStartPurchase: autoStart)
        self.creditsPurchaseWindow = controller
    }

    private static func sanitizedCreditsPurchaseURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw) else { return nil }
        guard let host = url.host?.lowercased(), host.contains("chatgpt.com") else { return nil }
        let path = url.path.lowercased()
        let allowed = ["settings", "usage", "billing", "credits"]
        guard allowed.contains(where: { path.contains($0) }) else { return nil }
        return url.absoluteString
    }

    @objc func openStatusPage() {
        let preferred = self.lastMenuProvider
            ?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledProviders().first)

        let provider = preferred ?? .codex
        let meta = self.store.metadata(for: provider)
        let urlString = meta.statusPageURL ?? meta.statusLinkURL
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openTerminalCommand(_ sender: NSMenuItem) {
        let command = sender.representedObject as? String ?? "claude"
        Self.openTerminal(command: command)
    }

    @objc func openLoginToProvider(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func runSwitchAccount(_ sender: NSMenuItem) {
        if self.loginTask != nil {
            self.loginLogger.info("Switch Account tap ignored: login already in-flight")
            return
        }

        let rawProvider = sender.representedObject as? String
        let provider = rawProvider.flatMap(UsageProvider.init(rawValue:)) ?? self.lastMenuProvider ?? .codex
        self.loginLogger.info("Switch Account tapped", metadata: ["provider": provider.rawValue])

        self.loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeLoginProvider = nil
                self.loginTask = nil
            }
            self.activeLoginProvider = provider
            self.loginPhase = .requesting
            self.loginLogger.info("Starting login task", metadata: ["provider": provider.rawValue])

            let shouldRefresh = await self.runLoginFlow(provider: provider)
            if shouldRefresh {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await self.store.refresh()
                }
                self.loginLogger.info("Triggered refresh after login", metadata: ["provider": provider.rawValue])
            }
        }
    }

    @objc func showSettingsGeneral() {
        self.openSettings(tab: .general)
    }

    @objc func showSettingsAbout() {
        self.openSettings(tab: .about)
    }

    func openMenuFromShortcut() {
        if self.shouldMergeIcons {
            self.statusItem.button?.performClick(nil)
            return
        }

        let provider = self.resolvedShortcutProvider()
        // Use the lazy accessor to ensure the item exists
        let item = self.lazyStatusItem(for: provider)
        item.button?.performClick(nil)
    }

    private func openSettings(tab: PreferencesTab) {
        DispatchQueue.main.async {
            self.preferencesSelection.tab = tab
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .codexbarOpenSettings,
                object: nil,
                userInfo: ["tab": tab.rawValue])
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func copyError(_ sender: NSMenuItem) {
        if let err = sender.representedObject as? String {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(err, forType: .string)
        }
    }

    private static func openTerminal(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                CodexBarLog.logger(LogCategories.terminal).error(
                    "Failed to open Terminal",
                    metadata: ["error": String(describing: error)])
            }
        }
    }

    private func resolvedShortcutProvider() -> UsageProvider {
        if let last = self.lastMenuProvider, self.isEnabled(last) {
            return last
        }
        if let first = self.store.enabledProviders().first {
            return first
        }
        return .codex
    }

    func presentCodexLoginResult(_ result: CodexLoginRunner.Result) {
        switch result.outcome {
        case .success:
            return
        case .missingBinary:
            self.presentLoginAlert(
                title: "Codex CLI not found",
                message: "Install the Codex CLI (npm i -g @openai/codex) and try again.")
        case let .launchFailed(message):
            self.presentLoginAlert(title: "Could not start codex login", message: message)
        case .timedOut:
            self.presentLoginAlert(
                title: "Codex login timed out",
                message: self.trimmedLoginOutput(result.output))
        case let .failed(status):
            let statusLine = "codex login exited with status \(status)."
            let message = self.trimmedLoginOutput(result.output.isEmpty ? statusLine : result.output)
            self.presentLoginAlert(title: "Codex login failed", message: message)
        }
    }

    func presentClaudeLoginResult(_ result: ClaudeLoginRunner.Result) {
        switch result.outcome {
        case .success:
            return
        case .missingBinary:
            self.presentLoginAlert(
                title: "Claude CLI not found",
                message: "Install the Claude CLI (npm i -g @anthropic-ai/claude-code) and try again.")
        case let .launchFailed(message):
            self.presentLoginAlert(title: "Could not start claude /login", message: message)
        case .timedOut:
            self.presentLoginAlert(
                title: "Claude login timed out",
                message: self.trimmedLoginOutput(result.output))
        case let .failed(status):
            let statusLine = "claude /login exited with status \(status)."
            let message = self.trimmedLoginOutput(result.output.isEmpty ? statusLine : result.output)
            self.presentLoginAlert(title: "Claude login failed", message: message)
        }
    }

    func describe(_ outcome: CodexLoginRunner.Result.Outcome) -> String {
        switch outcome {
        case .success: "success"
        case .timedOut: "timedOut"
        case let .failed(status): "failed(status: \(status))"
        case .missingBinary: "missingBinary"
        case let .launchFailed(message): "launchFailed(\(message))"
        }
    }

    func describe(_ outcome: ClaudeLoginRunner.Result.Outcome) -> String {
        switch outcome {
        case .success: "success"
        case .timedOut: "timedOut"
        case let .failed(status): "failed(status: \(status))"
        case .missingBinary: "missingBinary"
        case let .launchFailed(message): "launchFailed(\(message))"
        }
    }

    func describe(_ outcome: GeminiLoginRunner.Result.Outcome) -> String {
        switch outcome {
        case .success: "success"
        case .missingBinary: "missingBinary"
        case let .launchFailed(message): "launchFailed(\(message))"
        }
    }

    func presentGeminiLoginResult(_ result: GeminiLoginRunner.Result) {
        guard let info = Self.geminiLoginAlertInfo(for: result) else { return }
        self.presentLoginAlert(title: info.title, message: info.message)
    }

    struct LoginAlertInfo: Equatable, Sendable {
        let title: String
        let message: String
    }

    nonisolated static func geminiLoginAlertInfo(for result: GeminiLoginRunner.Result) -> LoginAlertInfo? {
        switch result.outcome {
        case .success:
            nil
        case .missingBinary:
            LoginAlertInfo(
                title: "Gemini CLI not found",
                message: "Install the Gemini CLI (npm i -g @google/gemini-cli) and try again.")
        case let .launchFailed(message):
            LoginAlertInfo(title: "Could not open Terminal for Gemini", message: message)
        }
    }

    func presentLoginAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func trimmedLoginOutput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        if trimmed.isEmpty { return "No output captured." }
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return "\(trimmed[..<idx])…"
    }

    func postLoginNotification(for provider: UsageProvider) {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let title = "\(name) login successful"
        let body = "You can return to the app; authentication finished."
        AppNotifications.shared.post(idPrefix: "login-\(provider.rawValue)", title: title, body: body)
    }

    func presentCursorLoginResult(_ result: CursorLoginRunner.Result) {
        switch result.outcome {
        case .success:
            return
        case .cancelled:
            // User closed the window; no alert needed
            return
        case let .failed(message):
            self.presentLoginAlert(title: "Cursor login failed", message: message)
        }
    }

    func describe(_ outcome: CursorLoginRunner.Result.Outcome) -> String {
        switch outcome {
        case .success: "success"
        case .cancelled: "cancelled"
        case let .failed(message): "failed(\(message))"
        }
    }
}
