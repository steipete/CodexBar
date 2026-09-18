import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static func isClaudeConsumerAutoPipeline(
        provider: UsageProvider,
        context: ProviderFetchContext,
        hasAdminAPIKey: Bool,
        hasTokenAccount: Bool,
        removedTokenAccountAuthority: Bool) -> Bool
    {
        // Provider-specific by design: this gate protects Claude's consumer Auto source from Admin/token accounts.
        provider == .claude && context.sourceMode == .auto && !hasAdminAPIKey && !hasTokenAccount &&
            !removedTokenAccountAuthority
    }

    func clearClaudeHistoryFallbackEligibility(provider: UsageProvider) {
        // Provider-specific by design: only Claude owns the persisted quota-history fallback state.
        guard provider == .claude else { return }
        self.claudeHistoryFallbackEligible = false
    }

    func recordProviderFetchSuccessErrorState(provider: UsageProvider) {
        self.errors[provider.instanceID] = nil
        self.clearClaudeHistoryFallbackEligibility(provider: provider)
    }

    @discardableResult
    func prepareClaudeHistoryFallback(
        provider: UsageProvider,
        usesConsumerAutoPipeline: Bool,
        accountStateWasStable: Bool) -> Bool
    {
        // Provider-specific by design: only a stable Claude refresh may arm the Claude history fallback.
        guard provider == .claude else { return false }
        let eligible = usesConsumerAutoPipeline && accountStateWasStable
        self.claudeHistoryFallbackEligible = eligible
        return eligible && self.restoreClaudeHistorySnapshotIfNeeded()
    }

    nonisolated static func underlyingProviderTransportError(_ error: Error) -> Error {
        if let error = error as? DeepSeekPlatformTransportError {
            return error.underlyingError
        }
        // These owned OAuth error cases preserve transport identity inside their public wrappers.
        if case let .networkError(underlyingError) = error as? CodexOAuthFetchError {
            return underlyingError
        }
        if case let .networkError(underlyingError) = error as? CodexTokenRefresher.RefreshError {
            return underlyingError
        }
        if case let .networkError(underlyingError) = error as? VertexAIFetchError {
            return underlyingError
        }
        if case let .networkError(underlyingError) = error as? VertexAITokenRefresher.RefreshError {
            return underlyingError
        }
        return error
    }

    nonisolated static func errorIsCancellation(_ error: any Error) -> Bool {
        let transportError = self.underlyingProviderTransportError(error)
        if transportError is CancellationError {
            return true
        }
        if let urlError = transportError as? URLError, urlError.code == .cancelled {
            return true
        }
        let message = transportError.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return message == "cancelled" || message.contains("cancellationerror")
            || message.contains("cancelled")
    }

    nonisolated static func hasMatchingDeepSeekBalanceOwner(
        after error: Error,
        priorSnapshot: UsageSnapshot?) -> Bool
    {
        guard let error = error as? DeepSeekPlatformTransportError else { return true }
        // A validated Chrome profile does not prove that it supplied the previously published balance.
        guard let owner = error.owner else { return false }
        return priorSnapshot?.deepseekPlatformBalanceOwner == owner
    }

    nonisolated static func shouldSuppressProviderCancellation(
        _ error: Error,
        priorSnapshot: UsageSnapshot?) -> Bool
    {
        guard self.hasMatchingDeepSeekBalanceOwner(after: error, priorSnapshot: priorSnapshot) else { return false }
        return self.errorIsCancellation(error)
    }

    nonisolated static func shouldPreservePriorSnapshot(
        after error: Error,
        hadPriorData: Bool,
        priorSnapshot: UsageSnapshot? = nil) -> Bool
    {
        guard hadPriorData else { return false }
        guard self.hasMatchingDeepSeekBalanceOwner(after: error, priorSnapshot: priorSnapshot) else { return false }
        if self.underlyingProviderTransportError(error) is CancellationError {
            return true
        }
        if self.isPreservableNetworkTransportError(error) {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("cancelled") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet")
    }

    nonisolated static func lastAvailableFailedFetchKind(
        from attempts: [ProviderFetchAttempt]) -> ProviderFetchKind?
    {
        attempts.last { $0.wasAvailable && $0.errorDescription != nil }?.kind
    }

    nonisolated static func isClaudeCLIRateLimitFailure(_ error: Error) -> Bool {
        ClaudeUsageFetcher.isCLIRateLimitError(error)
    }

    nonisolated static func isClaudeCLIUsageParseFailure(_ error: Error) -> Bool {
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return !ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(message)
        }
        if case let ClaudeUsageError.parseFailed(message) = error {
            return !ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(message)
        }
        return false
    }

    /// Rebuilds only Claude's quota bars from persisted captures. Identity and source authority intentionally stay
    /// unset: history proves the percentages and capture time, but it must never impersonate a live account fetch.
    @discardableResult
    func restoreClaudeHistorySnapshotIfNeeded() -> Bool {
        // Provider-specific by design: this reconstructs only Claude quota bars in Claude's isolated state lanes.
        guard self.claudeHistoryFallbackEligible,
              self.planUtilizationHistoryLoaded,
              self.settings.claudeUsageDataSource == .auto,
              self.settings.effectiveSelectedTokenAccount(for: .claude) == nil,
              self.snapshots[.claude] == nil
        else {
            return false
        }

        let histories = self.planUtilizationHistorySelection(for: .claude).histories
        let session = Self.latestClaudeHistoryEntry(
            named: .session,
            preferredWindowMinutes: Self.sessionWindowMinutes,
            histories: histories)
        let weekly = Self.latestClaudeHistoryEntry(
            named: .weekly,
            preferredWindowMinutes: Self.weeklyWindowMinutes,
            histories: histories)
        let opus = Self.latestClaudeHistoryEntry(
            named: .opus,
            preferredWindowMinutes: Self.weeklyWindowMinutes,
            histories: histories)
        let captures = [session?.entry.capturedAt, weekly?.entry.capturedAt, opus?.entry.capturedAt]
            .compactMap(\.self)
        guard let capturedAt = captures.max() else { return false }

        let snapshot = UsageSnapshot(
            primary: session.map(Self.rateWindow(from:)),
            secondary: weekly.map(Self.rateWindow(from:)),
            tertiary: opus.map(Self.rateWindow(from:)),
            updatedAt: capturedAt,
            dataConfidence: .percentOnly)
        // Provider-specific by design: reconstructed history is published only to Claude's snapshot/reset lanes.
        self.snapshots[.claude] = snapshot
        self.lastKnownResetSnapshots[.claude] = snapshot
        return true
    }

    private nonisolated static func latestClaudeHistoryEntry(
        named name: PlanUtilizationSeriesName,
        preferredWindowMinutes: Int,
        histories: [PlanUtilizationSeriesHistory])
        -> (windowMinutes: Int, entry: PlanUtilizationHistoryEntry)?
    {
        let named = histories.filter { $0.name == name && !$0.entries.isEmpty }
        let candidates = named.filter { $0.windowMinutes == preferredWindowMinutes }.isEmpty
            ? named
            : named.filter { $0.windowMinutes == preferredWindowMinutes }
        return candidates.compactMap { history in
            history.entries.last.map { (history.windowMinutes, $0) }
        }.max { lhs, rhs in
            lhs.1.capturedAt < rhs.1.capturedAt
        }
    }

    private nonisolated static func rateWindow(
        from value: (windowMinutes: Int, entry: PlanUtilizationHistoryEntry)) -> RateWindow
    {
        RateWindow(
            usedPercent: value.entry.usedPercent,
            windowMinutes: value.windowMinutes,
            resetsAt: value.entry.resetsAt,
            resetDescription: nil)
    }
}
