import CodexBarCore

@MainActor
extension StatusItemController {
    func runCursorLoginFlow() async -> Bool {
        // Acquire cache ownership before retiring refreshes so a cancellation-ignoring refresh cannot write in the
        // gap. CursorLoginRunner also holds a nested gate for standalone callers and tests.
        let cacheMutationGate = CookieHeaderCache.beginConditionalMutationGate(provider: .cursor)
        defer { CookieHeaderCache.endConditionalMutationGate(cacheMutationGate) }

        let currentSnapshot = self.store.snapshot(for: .cursor)
        let currentIdentity = currentSnapshot?.identity(for: .cursor)
        let accountPolicy = CursorLoginRunner.accountPolicy(
            configuredSource: self.settings.cursorCookieSource,
            identity: currentIdentity,
            hasPriorSnapshot: currentSnapshot != nil)

        // Stop older refreshes from publishing while the interactive login replaces the session.
        self.store.invalidateProviderRefreshRequests(.cursor)
        let cursorRunner = CursorLoginRunner(
            browserDetection: self.store.browserDetection,
            priorAccount: accountPolicy.priorAccount,
            requiresAccountConfirmation: accountPolicy.requiresConfirmation,
            replaceSessionCache: { session in
                await CursorLoginRunner.replaceCachedSession(session) {
                    // Finalize without suspending: future refreshes use the chosen cached browser session,
                    // while any refresh that started during the interactive flow loses publication ownership.
                    self.settings.cursorCookieSource = .auto
                    self.store.invalidateProviderRefreshRequests(.cursor)
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
        self.loginLogger.info("Cursor login", metadata: ["outcome": outcome])
        if case .success = result.outcome {
            self.postLoginNotification(for: .cursor)
            return true
        }
        return false
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
