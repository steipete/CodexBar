import CodexBarCore
import Foundation

extension UsageStore {
    struct CodexRefreshOutcomeResolution {
        let provider: UsageProvider
        let initialOutcome: ProviderFetchOutcome
        let expectedGuard: CodexAccountScopedRefreshGuard?
        let previousSnapshot: UsageSnapshot?
        let missingWindowBackfillSnapshot: UsageSnapshot?
        let fetchOutcome: @Sendable () async -> ProviderFetchOutcome
        let generation: UInt64
    }

    nonisolated static func isCodexPATOutcome(_ outcome: ProviderFetchOutcome) -> Bool {
        guard case let .success(result) = outcome.result else { return false }
        return result.strategyID == "codex.pat" || result.sourceLabel == "pat"
    }

    nonisolated static func codexPublicationRefreshOverrides(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        explicitPAT: Bool,
        expectedGuard: CodexAccountScopedRefreshGuard?,
        limitResetOwnerKey: CodexLimitResetOwnerKey?) -> (
        CodexAccountScopedRefreshGuard?,
        CodexLimitResetOwnerKey?)
    {
        let publishesPAT = provider == .codex && self.isCodexPATOutcome(outcome)
        let explicitPATFailure = explicitPAT && {
            if case .failure = outcome.result { return true }
            return false
        }()
        if publishesPAT || explicitPATFailure {
            return (nil, publishesPAT ? nil : limitResetOwnerKey)
        }
        return (expectedGuard, limitResetOwnerKey)
    }

    func resolvedCodexRefreshOutcome(
        _ resolution: CodexRefreshOutcomeResolution) async -> ProviderFetchOutcome?
    {
        guard resolution.provider == .codex else { return resolution.initialOutcome }
        if case let .success(result) = resolution.initialOutcome.result,
           !Self.isCodexPATOutcome(resolution.initialOutcome),
           let expectedGuard = resolution.expectedGuard,
           !self.shouldApplyCodexUsageResult(
               expectedGuard: expectedGuard,
               usage: result.usage.scoped(to: .codex))
        {
            self.retireCodexStateIfRefreshOwnerChanged(
                expectedGuard: expectedGuard,
                generation: resolution.generation)
            return nil
        }
        guard let admittedOutcome = await Self.codexOutcomeAdmittedForPublication(
            initialOutcome: resolution.initialOutcome,
            previousSnapshot: resolution.previousSnapshot,
            missingWindowBackfillSnapshot: resolution.missingWindowBackfillSnapshot,
            fetchConfirmation: resolution.fetchOutcome)
        else {
            if let expectedGuard = resolution.expectedGuard {
                self.retireCodexStateIfRefreshOwnerChanged(
                    expectedGuard: expectedGuard,
                    generation: resolution.generation)
            }
            return nil
        }
        if case let .success(result) = admittedOutcome.result,
           !Self.isCodexPATOutcome(admittedOutcome),
           let expectedGuard = resolution.expectedGuard,
           !self.shouldApplyCodexUsageResult(
               expectedGuard: expectedGuard,
               usage: result.usage.scoped(to: .codex))
        {
            self.retireCodexStateIfRefreshOwnerChanged(
                expectedGuard: expectedGuard,
                generation: resolution.generation)
            return nil
        }
        return admittedOutcome
    }
}
