import CodexBarCore
import Foundation

extension UsageStore {
    typealias CodexWeeklyConfirmationFetch = @Sendable () async -> ProviderFetchOutcome

    private struct CodexWeeklyResetPublicationTrace {
        let previousSnapshot: UsageSnapshot?
        let missingWindowBackfillSnapshot: UsageSnapshot?
        let publicationBaseline: UsageSnapshot?
        let initialSnapshot: UsageSnapshot
        let confirmationSnapshot: UsageSnapshot?
    }

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

        let initialDecision = CodexWeeklyResetConfirmation.initialDecision(
            previous: publicationBaseline,
            initial: rawInitialSnapshot)
        if initialDecision != .publishInitial {
            Self.logCodexWeeklyResetPublicationDecision(
                stage: "initial",
                decision: String(describing: initialDecision),
                trace: CodexWeeklyResetPublicationTrace(
                    previousSnapshot: previousSnapshot,
                    missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
                    publicationBaseline: publicationBaseline,
                    initialSnapshot: rawInitialSnapshot,
                    confirmationSnapshot: nil))
        }
        switch initialDecision {
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
        let confirmationTrace = CodexWeeklyResetPublicationTrace(
            previousSnapshot: previousSnapshot,
            missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
            publicationBaseline: publicationBaseline,
            initialSnapshot: rawInitialSnapshot,
            confirmationSnapshot: confirmationSnapshot)
        guard CodexIdentityResolver.normalizeEmail(rawInitialSnapshot.accountEmail(for: .codex)) ==
            CodexIdentityResolver.normalizeEmail(confirmationSnapshot.accountEmail(for: .codex))
        else {
            Self.logCodexWeeklyResetPublicationDecision(
                stage: "confirmation",
                decision: "preservePreviousAccountMismatch",
                trace: confirmationTrace)
            return nil
        }
        let confirmationDecision = CodexWeeklyResetConfirmation.confirmationDecision(
            previous: publicationBaseline,
            previousEvidence: previousSnapshot,
            initial: rawInitialSnapshot,
            confirmation: confirmationSnapshot)
        Self.logCodexWeeklyResetPublicationDecision(
            stage: "confirmation",
            decision: String(describing: confirmationDecision),
            trace: confirmationTrace)
        switch confirmationDecision {
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

    private nonisolated static func logCodexWeeklyResetPublicationDecision(
        stage: String,
        decision: String,
        trace: CodexWeeklyResetPublicationTrace)
    {
        var metadata: [String: String] = [
            "stage": stage,
            "decision": decision,
        ]
        Self.appendCodexWeeklyResetTrace(
            snapshot: trace.previousSnapshot,
            prefix: "previousSnapshot",
            metadata: &metadata)
        Self.appendCodexWeeklyResetTrace(
            snapshot: trace.missingWindowBackfillSnapshot,
            prefix: "missingWindowBackfillSnapshot",
            metadata: &metadata)
        Self.appendCodexWeeklyResetTrace(
            snapshot: trace.publicationBaseline,
            prefix: "publicationBaseline",
            metadata: &metadata)
        Self.appendCodexWeeklyResetTrace(
            snapshot: trace.initialSnapshot,
            prefix: "initial",
            metadata: &metadata)
        Self.appendCodexWeeklyResetTrace(
            snapshot: trace.confirmationSnapshot,
            prefix: "confirmation",
            metadata: &metadata)
        metadata["initialConfirmationAccountMatches"] = Self.codexWeeklyResetCompatibility(
            snapshots: [trace.initialSnapshot, trace.confirmationSnapshot],
            value: { CodexIdentityResolver.normalizeEmail($0.accountEmail(for: .codex)) })
        metadata["stableAccountCompatible"] = Self.codexWeeklyResetCompatibility(
            snapshots: [trace.previousSnapshot, trace.initialSnapshot, trace.confirmationSnapshot],
            value: { CodexIdentityResolver.normalizeEmail($0.accountEmail(for: .codex)) })
        metadata["stablePlanCompatible"] = Self.codexWeeklyResetCompatibility(
            snapshots: [trace.previousSnapshot, trace.initialSnapshot, trace.confirmationSnapshot],
            value: { snapshot in
                snapshot.loginMethod(for: .codex)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            })
        CodexBarLog.logger(LogCategories.provider(.codex, scope: "weekly-reset-publication")).debug(
            "Codex weekly reset publication decision",
            metadata: metadata)
    }

    private nonisolated static func codexWeeklyResetCompatibility(
        snapshots: [UsageSnapshot?],
        value: (UsageSnapshot) -> String?) -> String
    {
        let values = snapshots.map { $0.flatMap(value) }
        guard let first = values.compactMap(\.self).first,
              values.allSatisfy({ $0 != nil })
        else {
            return "unknown"
        }
        return String(values.allSatisfy { $0 == first })
    }

    private nonisolated static func appendCodexWeeklyResetTrace(
        snapshot: UsageSnapshot?,
        prefix: String,
        metadata: inout [String: String])
    {
        guard let snapshot else {
            metadata["\(prefix).present"] = "false"
            return
        }
        let weekly = CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: snapshot)
        metadata["\(prefix).present"] = "true"
        metadata["\(prefix).updatedAt"] = String(format: "%.0f", snapshot.updatedAt.timeIntervalSince1970)
        metadata["\(prefix).weeklyUsedPercent"] = weekly.map { String(format: "%.3f", $0.usedPercent) } ?? "nil"
        metadata["\(prefix).resetBoundary"] = weekly?.resetsAt.map {
            String(format: "%.0f", $0.timeIntervalSince1970)
        } ?? "nil"
        metadata["\(prefix).accountKnown"] = String(
            CodexIdentityResolver.normalizeEmail(snapshot.accountEmail(for: .codex)) != nil)
        metadata["\(prefix).planKnown"] = String(snapshot.loginMethod(for: .codex) != nil)
        metadata["\(prefix).creditsPresent"] = String(snapshot.codexResetCredits != nil)
        metadata["\(prefix).creditsAvailableCount"] = snapshot.codexResetCredits.map {
            String($0.availableCount)
        } ?? "nil"
    }
}
