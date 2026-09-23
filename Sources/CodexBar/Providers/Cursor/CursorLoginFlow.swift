import CodexBarCore

@MainActor
extension StatusItemController {
    func runCursorLoginFlow() async -> Bool {
        await self.runCursorHostedLoginFlow(provider: .cursor)
    }

    func runGrokBotLoginFlow() async -> Bool {
        await self.runCursorHostedLoginFlow(provider: .grokbot)
    }

    private func runCursorHostedLoginFlow(provider: UsageProvider) async -> Bool {
        // Acquire cache ownership before retiring refreshes so a cancellation-ignoring refresh cannot write in the
        // gap. CursorLoginRunner also holds a nested gate for standalone callers and tests.
        let cacheMutationGate = CookieHeaderCache.beginConditionalMutationGate(provider: provider)
        defer { CookieHeaderCache.endConditionalMutationGate(cacheMutationGate) }

        let currentSnapshot = self.store.snapshot(for: provider)
        let currentIdentity = currentSnapshot?.identity(for: provider)
        let configuredSource = self.cookieSource(for: provider)
        let accountPolicy = CursorLoginRunner.accountPolicy(
            configuredSource: configuredSource,
            identity: currentIdentity,
            hasPriorSnapshot: currentSnapshot != nil)

        // Stop older refreshes from publishing while the interactive login replaces the session.
        self.store.invalidateProviderRefreshRequests(provider)
        let clearSharedSessionStore = provider == .cursor
        let cursorRunner = CursorLoginRunner(
            browserDetection: self.store.browserDetection,
            priorAccount: accountPolicy.priorAccount,
            requiresAccountConfirmation: accountPolicy.requiresConfirmation,
            replaceSessionCache: { session in
                await CursorLoginRunner.replaceCachedSession(
                    session,
                    provider: provider,
                    clearSharedSessionStore: clearSharedSessionStore)
                {
                    // Finalize without suspending: future refreshes use the chosen cached browser session,
                    // while any refresh that started during the interactive flow loses publication ownership.
                    self.setCookieSource(.auto, for: provider)
                    self.store.invalidateProviderRefreshRequests(provider)
                }
            })
        let phaseHandler: @MainActor (CursorLoginRunner.Phase) -> Void = { [weak self] phase in
            switch phase {
            case .loading, .waitingLogin:
                self?.loginPhase = .waitingBrowser
            case .success, .failed:
                self?.loginPhase = .idle
            }
        }
        let result = await cursorRunner.run(onPhaseChange: phaseHandler)
        guard Self.shouldFinalizeCursorLoginResult(result, taskIsCancelled: Task.isCancelled) else { return false }
        self.loginPhase = .idle
        self.presentCursorLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Cursor login", metadata: ["outcome": outcome, "provider": provider.rawValue])
        if case .success = result.outcome {
            self.postLoginNotification(for: provider)
            return true
        }
        return false
    }

    private func cookieSource(for provider: UsageProvider) -> ProviderCookieSource {
        switch provider {
        case .cursor: self.settings.cursorCookieSource
        case .grokbot: self.settings.grokbotCookieSource
        default: .off
        }
    }

    private func setCookieSource(_ source: ProviderCookieSource, for provider: UsageProvider) {
        switch provider {
        case .cursor: self.settings.cursorCookieSource = source
        case .grokbot: self.settings.grokbotCookieSource = source
        default: break
        }
    }

    nonisolated static func shouldFinalizeCursorLoginResult(
        _ result: CursorLoginRunner.Result,
        taskIsCancelled: Bool) -> Bool
    {
        if case .success = result.outcome {
            return true
        }
        return !taskIsCancelled
    }
}
