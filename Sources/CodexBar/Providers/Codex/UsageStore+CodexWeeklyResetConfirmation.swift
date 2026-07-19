import CodexBarCore

extension UsageStore {
    typealias CodexWeeklyConfirmationFetch = @Sendable () async -> ProviderFetchOutcome

    nonisolated static func codexOutcomeAdmittedForPublication(
        initialOutcome: ProviderFetchOutcome,
        previousSnapshot: UsageSnapshot?,
        missingWindowBackfillSnapshot: UsageSnapshot?,
        fetchConfirmation: @escaping CodexWeeklyConfirmationFetch) async -> ProviderFetchOutcome?
    {
        guard case let .success(rawInitialResult) = initialOutcome.result else { return initialOutcome }
        let rawInitialSnapshot = rawInitialResult.usage.scoped(to: .codex)
        let publicationBaseline = [previousSnapshot, missingWindowBackfillSnapshot]
            .compactMap(\.self)
            .max { $0.updatedAt < $1.updatedAt }
        let publicationInitialOutcome = if let missingWindowBackfillSnapshot {
            initialOutcome.replacingUsage(Self.codexBackfillingResetWindows(
                rawInitialSnapshot,
                from: missingWindowBackfillSnapshot))
        } else {
            initialOutcome
        }

        if CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: rawInitialSnapshot) == nil {
            guard rawInitialSnapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  previousSnapshot.map({
                      $0.updatedAt.timeIntervalSinceReferenceDate.isFinite &&
                          rawInitialSnapshot.updatedAt > $0.updatedAt
                  }) ?? true,
                  missingWindowBackfillSnapshot.map({
                      $0.updatedAt.timeIntervalSinceReferenceDate.isFinite &&
                          rawInitialSnapshot.updatedAt >= $0.updatedAt
                  }) ?? true
            else {
                return nil
            }
            if CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: publicationBaseline) != nil,
               case let .success(publicationResult) = publicationInitialOutcome.result,
               CodexConsumerProjection.sourceRateWindow(
                   for: .weekly,
                   snapshot: publicationResult.usage.scoped(to: .codex)) == nil
            {
                return nil
            }
            return publicationInitialOutcome
        }

        switch CodexWeeklyResetConfirmation.initialDecision(
            previous: publicationBaseline,
            initial: rawInitialSnapshot)
        {
        case .publishInitial:
            return publicationInitialOutcome
        case .preservePrevious:
            return nil
        case .requiresConfirmation:
            break
        }

        guard !Task.isCancelled else { return nil }
        let confirmationOutcome = await fetchConfirmation()
        guard !Task.isCancelled,
              case let .success(confirmationResult) = confirmationOutcome.result
        else {
            return nil
        }
        let confirmationSnapshot = confirmationResult.usage.scoped(to: .codex)
        guard CodexIdentityResolver.normalizeEmail(rawInitialSnapshot.accountEmail(for: .codex)) ==
            CodexIdentityResolver.normalizeEmail(confirmationSnapshot.accountEmail(for: .codex))
        else {
            return nil
        }
        switch CodexWeeklyResetConfirmation.confirmationDecision(
            previous: publicationBaseline,
            initial: rawInitialSnapshot,
            confirmation: confirmationSnapshot)
        {
        case .publishConfirmation:
            if let missingWindowBackfillSnapshot {
                return confirmationOutcome.replacingUsage(Self.codexBackfillingResetWindows(
                    confirmationSnapshot,
                    from: missingWindowBackfillSnapshot))
            }
            return confirmationOutcome
        case .preservePrevious:
            return nil
        }
    }
}
