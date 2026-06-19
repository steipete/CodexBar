import AppKit
import CodexBarCore

enum LoginNotificationLogic {
    static func notificationCopy(providerName: String) -> (title: String, body: String) {
        (
            L("login_success_notification_title", providerName),
            L("login_success_notification_body"))
    }
}

extension StatusItemController: StatusItemMenuPersistentActionDelegate {
    // MARK: - Actions reachable from menus

    func refreshStore(
        forceTokenUsage: Bool,
        refreshOpenMenusWhenComplete: Bool = true,
        interaction: ProviderInteraction = .userInitiated)
    {
        Task {
            await self.performStoreRefresh(
                forceTokenUsage: forceTokenUsage,
                refreshOpenMenusWhenComplete: refreshOpenMenusWhenComplete,
                interaction: interaction)
        }
    }

    func performStoreRefresh(
        forceTokenUsage: Bool,
        refreshOpenMenusWhenComplete: Bool,
        interaction: ProviderInteraction) async
    {
        await ProviderInteractionContext.$current.withValue(interaction) {
            await self.store.refresh(forceTokenUsage: forceTokenUsage)
            guard !Task.isCancelled, !self.hasPreparedForAppShutdown else { return }
            self.store.scheduleStorageFootprintRefreshForOverview(force: true)
            if refreshOpenMenusWhenComplete {
                self.refreshOpenMenusAfterExplicitStoreAction()
            } else {
                self.invalidateMenus()
            }
        }
    }

    func refreshOpenMenusAfterExplicitStoreAction() {
        self.invalidateMenus(
            refreshOpenMenus: true,
            deferOpenParentMenuRebuild: true)
    }

    @objc func refreshNow() {
        guard !self.hasPreparedForAppShutdown,
              self.manualRefreshTask == nil,
              !self.store.isRefreshing
        else { return }

        let frozenModels = self.frozenManualRefreshMenuCardModels()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.manualRefreshTask = nil
                self.menuCardRefreshMonitor.endManualRefresh()
                self.updatePersistentRefreshRowsInProgress()
            }
            guard !Task.isCancelled, !self.hasPreparedForAppShutdown else { return }
            #if DEBUG
            if let operation = self._test_manualRefreshOperation {
                await operation()
                guard !Task.isCancelled, !self.hasPreparedForAppShutdown else { return }
                return
            }
            #endif
            await self.performStoreRefresh(
                forceTokenUsage: true,
                refreshOpenMenusWhenComplete: true,
                interaction: .userInitiated)
        }
        self.manualRefreshTask = task
        self.menuCardRefreshMonitor.beginManualRefresh(frozenModels: frozenModels)
        self.updatePersistentRefreshRowsInProgress()
    }

    private func frozenManualRefreshMenuCardModels() -> [UsageProvider: UsageMenuCardView.Model] {
        var providers = self.store.enabledProvidersForDisplay()
        if let lastMenuProvider,
           !providers.contains(lastMenuProvider)
        {
            providers.append(lastMenuProvider)
        }
        if providers.isEmpty,
           let defaultProvider = self.settings.orderedProviders().first ?? UsageProvider.allCases.first
        {
            providers.append(defaultProvider)
        }

        var models: [UsageProvider: UsageMenuCardView.Model] = [:]
        for provider in providers {
            models[provider] = self.menuCardModel(for: provider)
        }
        return models
    }

    nonisolated func performPersistentRefreshAction() {
        Task { @MainActor [weak self] in
            self?.refreshNow()
        }
    }

    nonisolated func performPersistentSettingsAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.closeOpenMenusFromShortcutIfNeeded()
            self.showSettingsGeneral()
        }
    }

    nonisolated func performPersistentQuitAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.closeOpenMenusFromShortcutIfNeeded()
            self.quit()
        }
    }

    nonisolated func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection) {
        Task { @MainActor [weak self] in
            self?.navigateProviderSwitcher(direction)
        }
    }

    @objc func refreshAugmentSession() {
        Task {
            await self.store.forceRefreshAugmentSession()
            // Also trigger a full refresh to update the menu and clear any stale errors
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refresh(forceTokenUsage: false)
            }
            self.refreshOpenMenusAfterExplicitStoreAction()
        }
    }

    @objc func installUpdate() {
        self.updater.installUpdate()
    }

    @objc func openDashboard() {
        let preferred = self.lastMenuProvider
            ?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledProviders().first)

        let provider = preferred ?? .codex
        guard let url = self.dashboardURL(for: provider) else { return }
        NSWorkspace.shared.open(url)
    }

    func dashboardURL(
        for provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        if provider == .alibaba {
            return self.settings.alibabaCodingPlanAPIRegion.dashboardURL
        }
        if provider == .minimax {
            return self.settings.minimaxAPIRegion.dashboardURL
        }

        if provider == .opencodego {
            return self.settings.opencodegoDashboardURL
        }

        if provider == .zai {
            return ZaiUsageFetcher.resolveDashboardURL(
                region: self.settings.zaiAPIRegion,
                environment: environment)
        }

        let meta = self.store.metadata(for: provider)
        let urlString: String? = if provider == .claude, self.store.isClaudeSubscription() {
            meta.subscriptionDashboardURL ?? meta.dashboardURL
        } else {
            meta.dashboardURL
        }

        guard let urlString else { return nil }
        return URL(string: urlString)
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

    static func sanitizedCreditsPurchaseURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw) else { return nil }
        guard Self.isAllowedChatGPTPurchaseHost(url) else { return nil }
        let pathComponents = url.pathComponents.map { $0.lowercased() }
        let allowed = ["settings", "usage", "billing", "credits"]
        guard pathComponents.contains(where: { allowed.contains($0) }) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private static func isAllowedChatGPTPurchaseHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
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

    @objc func openChangelog() {
        let preferred = self.lastMenuProvider
            ?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledProviders().first)

        let provider = preferred ?? .codex
        let meta = self.store.metadata(for: provider)
        guard let urlString = meta.changelogURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openTerminalCommand(_ sender: NSMenuItem) {
        let command = sender.representedObject as? String ?? "claude"
        self.openTerminal(command: command)
    }

    @objc func openLoginToProvider(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func addManagedCodexAccountFromMenu(_: NSMenuItem) {
        guard self.codexAccountPromotionCoordinator.isInteractionBlocked() == false else {
            self.loginLogger.info("Add Account tap ignored: Codex account change already in-flight")
            return
        }
        guard self.settings.hasUnreadableManagedCodexAccountStore == false else {
            self.presentLoginAlert(
                title: L("Managed Codex accounts unavailable"),
                message: L(
                    "CodexBar could not read managed account storage. " +
                        "Recover the store before adding another account."))
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let account = try await self.managedCodexAccountCoordinator.authenticateManagedAccount()
                self.settings.selectAuthenticatedManagedCodexAccount(account)
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await self.store.refreshCodexAccountScopedState(allowDisabled: true)
                }
            } catch {
                self.presentManagedCodexAccountError(error)
            }
        }
    }

    @objc func requestCodexSystemPromotionFromMenu(_ sender: NSMenuItem) {
        guard let rawManagedAccountID = sender.representedObject as? String,
              let managedAccountID = UUID(uuidString: rawManagedAccountID)
        else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.codexAccountPromotionCoordinator.promote(managedAccountID: managedAccountID)
            if case let .failure(error) = result {
                self.presentLoginAlert(title: error.title, message: error.message)
            }
        }
    }

    @objc func runSwitchAccount(_ sender: NSMenuItem) {
        if self.loginTask != nil {
            self.loginLogger.info("Switch Account tap ignored: login already in-flight")
            return
        }

        let rawProvider = sender.representedObject as? String
        let provider = rawProvider.flatMap(UsageProvider.init(rawValue:)) ?? self.lastMenuProvider ?? .codex
        self.loginLogger.info("Switch Account tapped", metadata: ["provider": provider.rawValue])
        self.startLoginFlow(provider: provider)
    }

    func runLoginFlowFromSettings(provider: UsageProvider) async {
        guard self.loginTask == nil else {
            self.loginLogger.info(
                "Settings login tap ignored: login already in-flight",
                metadata: ["provider": provider.rawValue])
            return
        }
        self.startLoginFlow(provider: provider)
        await self.loginTask?.value
    }

    @objc func showSettingsGeneral() {
        self.openSettings(tab: .general)
    }

    @objc func showSettingsAbout() {
        self.openSettings(tab: .about)
    }

    func openMenuFromShortcut() {
        if self.closeOpenMenusFromShortcutIfNeeded() {
            return
        }

        if self.shouldMergeIcons {
            self.statusItem.button?.performClick(nil)
            return
        }

        let provider = self.resolvedShortcutProvider()
        // Use the lazy accessor to ensure the item exists
        let item = self.lazyStatusItem(for: provider)
        item.button?.performClick(nil)
    }

    @discardableResult
    func closeOpenMenusFromShortcutIfNeeded() -> Bool {
        guard !self.openMenus.isEmpty else { return false }

        let menus = Array(self.openMenus.values)
        for menu in menus {
            menu.cancelTrackingWithoutAnimation()
            self.forgetClosedMenu(menu)
        }
        return true
    }

    func celebrationOriginPoint(for provider: UsageProvider?) -> CGPoint? {
        let item: NSStatusItem = if self.shouldMergeIcons {
            self.statusItem
        } else if let provider, let existing = self.statusItems[provider], existing.isVisible {
            existing
        } else {
            self.lazyStatusItem(for: provider ?? .codex)
        }

        guard let button = item.button,
              let window = button.window
        else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let screenFrame = window.convertToScreen(buttonFrameInWindow)
        return CGPoint(x: screenFrame.midX, y: screenFrame.midY)
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
        let openMenus = Array(self.openMenus.values)
        for menu in openMenus {
            menu.cancelTrackingWithoutAnimation()
        }

        self.scheduleQuitTermination { [weak self] in
            guard let self else { return }
            self.prepareForAppShutdown()
            self.terminateApplicationForQuit()
        }
    }

    @objc func copyError(_ sender: NSMenuItem) {
        if let err = sender.representedObject as? String {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(err, forType: .string)
        }
    }

    func openTerminal(command: String) {
        let terminal = self.settings.terminalApp

        if terminal == .iTerm, !terminal.isInstalled {
            CodexBarLog.logger(LogCategories.terminal).warning(
                "iTerm is not installed, falling back to Terminal.app",
                metadata: ["terminal": terminal.rawValue])
            Self.openTerminalInDefaultTerminal(command: command)
            return
        }

        if Self.executeAppleScript(terminal.appleScript(command: command)) {
            return
        }
        guard terminal != .terminal else { return }

        CodexBarLog.logger(LogCategories.terminal).warning(
            "\(terminal.label) AppleScript failed, falling back to Terminal.app",
            metadata: ["terminal": terminal.rawValue])
        Self.openTerminalInDefaultTerminal(command: command)
    }

    private static func openTerminalInDefaultTerminal(command: String) {
        self.executeAppleScript(TerminalApp.terminal.appleScript(command: command))
    }

    /// Executes an AppleScript and returns `true` on success, `false` on failure.
    @discardableResult
    private static func executeAppleScript(_ source: String) -> Bool {
        if let appleScript = NSAppleScript(source: source) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                CodexBarLog.logger(LogCategories.terminal).error(
                    "Failed to execute AppleScript",
                    metadata: ["error": String(describing: error)])
                return false
            }
            return true
        }
        CodexBarLog.logger(LogCategories.terminal).error("Failed to compile AppleScript")
        return false
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

    private func startLoginFlow(provider: UsageProvider) {
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

    func presentCodexLoginResult(_ result: CodexLoginRunner.Result) {
        guard let info = CodexLoginAlertPresentation.alertInfo(for: result) else { return }
        self.presentLoginAlert(title: info.title, message: info.message)
    }

    private func presentManagedCodexAccountError(_ error: Error) {
        let info = if let error = error as? ManagedCodexAccountCoordinatorError,
                      error == .authenticationInProgress
        {
            LoginAlertInfo(
                title: L("Codex account login already running"),
                message: L("Wait for the current managed Codex login to finish before adding another account."))
        } else if let error = error as? ManagedCodexAccountServiceError {
            LoginAlertInfo(title: L("Could not add Codex account"), message: error.userFacingMessage)
        } else {
            LoginAlertInfo(title: L("Could not add Codex account"), message: error.localizedDescription)
        }

        self.presentLoginAlert(title: info.title, message: info.message)
    }

    func presentClaudeLoginResult(_ result: ClaudeLoginRunner.Result) {
        switch result.outcome {
        case .success:
            return
        case .missingBinary:
            self.presentLoginAlert(
                title: L("Claude CLI not found"),
                message: L("Install the Claude CLI (npm i -g @anthropic-ai/claude-code) and try again."))
        case let .launchFailed(message):
            self.presentLoginAlert(title: L("Could not start claude /login"), message: message)
        case .timedOut:
            self.presentLoginAlert(
                title: L("Claude login timed out"),
                message: self.trimmedLoginOutput(result.output))
        case let .failed(status):
            let statusLine = String(format: L("claude /login exited with status %d."), status)
            let message = self.trimmedLoginOutput(result.output.isEmpty ? statusLine : result.output)
            self.presentLoginAlert(title: L("Claude login failed"), message: message)
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

    func describe(_ outcome: AntigravityLoginRunner.Result.Outcome) -> String {
        switch outcome {
        case let .success(email):
            "success(email: \(email ?? "nil"))"
        case .cancelled:
            "cancelled"
        case .timedOut:
            "timedOut"
        case let .launchFailed(message):
            "launchFailed(\(message))"
        case let .failed(message):
            "failed(\(message))"
        }
    }

    func presentGeminiLoginResult(_ result: GeminiLoginRunner.Result) {
        guard let info = Self.geminiLoginAlertInfo(for: result) else { return }
        self.presentLoginAlert(title: info.title, message: info.message)
    }

    func presentAntigravityLoginResult(_ result: AntigravityLoginRunner.Result) {
        guard let info = Self.antigravityLoginAlertInfo(for: result) else { return }
        self.presentLoginAlert(title: info.title, message: info.message)
    }

    struct LoginAlertInfo: Equatable {
        let title: String
        let message: String
    }

    nonisolated static func geminiLoginAlertInfo(for result: GeminiLoginRunner.Result) -> LoginAlertInfo? {
        switch result.outcome {
        case .success:
            nil
        case .missingBinary:
            LoginAlertInfo(
                title: L("Gemini CLI not found"),
                message: L("Install the Gemini CLI (npm i -g @google/gemini-cli) and try again."))
        case let .launchFailed(message):
            LoginAlertInfo(title: L("Could not open Terminal for Gemini"), message: message)
        }
    }

    nonisolated static func antigravityLoginAlertInfo(for result: AntigravityLoginRunner.Result) -> LoginAlertInfo? {
        switch result.outcome {
        case .success, .cancelled:
            nil
        case .timedOut:
            LoginAlertInfo(
                title: L("Antigravity login timed out"),
                message: L("The browser login did not complete in time. Try Antigravity login again."))
        case let .launchFailed(message):
            LoginAlertInfo(
                title: L("Could not open browser for Antigravity"),
                message: String(format: L("Open this URL manually to continue login:\n\n%@"), message))
        case let .failed(message):
            LoginAlertInfo(title: L("Antigravity login failed"), message: message)
        }
    }

    func presentLoginAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = L(title)
        alert.informativeText = L(message)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func trimmedLoginOutput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        if trimmed.isEmpty { return L("No output captured.") }
        if trimmed.count <= limit { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return "\(trimmed[..<idx])…"
    }

    func postLoginNotification(for provider: UsageProvider) {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let (title, body) = LoginNotificationLogic.notificationCopy(providerName: name)
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
            self.presentLoginAlert(title: L("Cursor login failed"), message: message)
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
