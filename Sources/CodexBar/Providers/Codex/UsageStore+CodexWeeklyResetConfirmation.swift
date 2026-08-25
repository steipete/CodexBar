import CodexBarCore
import Foundation

extension UsageStore {
    typealias CodexWeeklyConfirmationFetch = @Sendable () async -> ProviderFetchOutcome

    struct CodexWeeklyResetPublicationAdmission {
        let outcome: ProviderFetchOutcome?
        let pendingCandidate: CodexWeeklyResetPublicationCandidate?
    }

    private struct CodexWeeklyResetPublicationTrace {
        let previousSnapshot: UsageSnapshot?
        let missingWindowBackfillSnapshot: UsageSnapshot?
        let publicationBaseline: UsageSnapshot?
        let initialSnapshot: UsageSnapshot
        let confirmationSnapshot: UsageSnapshot?
    }

    private struct CodexMissingWeeklyAdmissionInput {
        let rawInitialSnapshot: UsageSnapshot
        let previousSnapshot: UsageSnapshot?
        let publicationBaseline: UsageSnapshot?
        let missingWindowBackfillSnapshot: UsageSnapshot?
        let publicationInitialOutcome: ProviderFetchOutcome
        let pendingCandidate: CodexWeeklyResetPublicationCandidate?
    }

    nonisolated static func codexOutcomeAdmittedForPublication(
        initialOutcome: ProviderFetchOutcome,
        previousSnapshot: UsageSnapshot?,
        previousSourceLabel: String?,
        missingWindowBackfillSnapshot: UsageSnapshot?,
        pendingCandidate: CodexWeeklyResetPublicationCandidate? = nil,
        observedAt: Date = CodexWeeklyResetConfirmation.observationDate,
        fetchConfirmation: @escaping CodexWeeklyConfirmationFetch) async -> CodexWeeklyResetPublicationAdmission
    {
        var candidateForRetry = pendingCandidate.flatMap {
            CodexWeeklyResetConfirmation.shouldRetainDelayedCandidate($0, observedAt: observedAt) ? $0 : nil
        }
        guard case let .success(rawInitialResult) = initialOutcome.result else {
            return CodexWeeklyResetPublicationAdmission(outcome: initialOutcome, pendingCandidate: candidateForRetry)
        }
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
            return Self.codexMissingWeeklyAdmission(input: CodexMissingWeeklyAdmissionInput(
                rawInitialSnapshot: rawInitialSnapshot,
                previousSnapshot: previousSnapshot,
                publicationBaseline: publicationBaseline,
                missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
                publicationInitialOutcome: publicationInitialOutcome,
                pendingCandidate: candidateForRetry))
        }

        let initialDecision = CodexWeeklyResetConfirmation.initialDecision(
            previous: publicationBaseline,
            initial: rawInitialSnapshot)
        Self.logCodexWeeklyResetInitialDecision(
            initialDecision,
            previousSnapshot: previousSnapshot,
            missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
            publicationBaseline: publicationBaseline,
            initialSnapshot: rawInitialSnapshot)
        switch initialDecision {
        case .publishInitial:
            return CodexWeeklyResetPublicationAdmission(
                outcome: publicationInitialOutcome,
                pendingCandidate: nil)
        case .preservePrevious:
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: Self.codexCandidateAfterPreservedInitial(
                    candidateForRetry,
                    previousSnapshot: previousSnapshot,
                    initialSnapshot: rawInitialSnapshot,
                    initialResult: rawInitialResult,
                    observedAt: observedAt))
        case .requiresConfirmation:
            break
        }

        if let pendingCandidate = candidateForRetry {
            let delayedDecision = CodexWeeklyResetConfirmation.delayedCandidateDecision(
                previous: previousSnapshot,
                candidate: pendingCandidate,
                current: rawInitialSnapshot,
                currentIsExactOAuth: Self.isExactCodexOAuthResult(rawInitialResult),
                observedAt: observedAt)
            Self.logCodexWeeklyResetPublicationDecision(
                stage: "delayedConfirmation",
                decision: String(describing: delayedDecision),
                trace: CodexWeeklyResetPublicationTrace(
                    previousSnapshot: previousSnapshot,
                    missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
                    publicationBaseline: publicationBaseline,
                    initialSnapshot: rawInitialSnapshot,
                    confirmationSnapshot: pendingCandidate.snapshot))
            switch delayedDecision {
            case .publishCurrent:
                return CodexWeeklyResetPublicationAdmission(
                    outcome: publicationInitialOutcome,
                    pendingCandidate: nil)
            case .retainCandidate:
                return CodexWeeklyResetPublicationAdmission(
                    outcome: nil,
                    pendingCandidate: pendingCandidate)
            case .discardCandidate:
                candidateForRetry = nil
            }
        }

        guard !Task.isCancelled else {
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: candidateForRetry)
        }
        let confirmationOutcome = await fetchConfirmation()
        guard !Task.isCancelled,
              case let .success(confirmationResult) = confirmationOutcome.result
        else {
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: candidateForRetry)
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
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: nil)
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
                return CodexWeeklyResetPublicationAdmission(
                    outcome: confirmationOutcome.replacingUsage(Self.codexBackfillingResetWindows(
                        confirmationSnapshot,
                        from: missingWindowBackfillSnapshot)),
                    pendingCandidate: nil)
            }
            return CodexWeeklyResetPublicationAdmission(
                outcome: confirmationOutcome,
                pendingCandidate: nil)
        case .preservePrevious:
            let candidate = CodexWeeklyResetConfirmation.makeDelayedCandidate(
                previous: previousSnapshot,
                initial: rawInitialSnapshot,
                confirmation: confirmationSnapshot,
                sourceEvidence: .init(
                    previousIsExactOAuth: previousSourceLabel?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "oauth",
                    initialIsExactOAuth: Self.isExactCodexOAuthResult(rawInitialResult),
                    confirmationIsExactOAuth: Self.isExactCodexOAuthResult(confirmationResult)),
                observedAt: observedAt)
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: candidate)
        }
    }

    private nonisolated static func codexMissingWeeklyAdmission(
        input: CodexMissingWeeklyAdmissionInput) -> CodexWeeklyResetPublicationAdmission
    {
        let rawInitialSnapshot = input.rawInitialSnapshot
        guard rawInitialSnapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              input.previousSnapshot.map({
                  $0.updatedAt.timeIntervalSinceReferenceDate.isFinite &&
                      rawInitialSnapshot.updatedAt > $0.updatedAt
              }) ?? true,
              input.missingWindowBackfillSnapshot.map({
                  $0.updatedAt.timeIntervalSinceReferenceDate.isFinite &&
                      rawInitialSnapshot.updatedAt >= $0.updatedAt
              }) ?? true
        else {
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: input.pendingCandidate)
        }
        if CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: input.publicationBaseline) != nil,
           case let .success(publicationResult) = input.publicationInitialOutcome.result,
           CodexConsumerProjection.sourceRateWindow(
               for: .weekly,
               snapshot: publicationResult.usage.scoped(to: .codex)) == nil
        {
            return CodexWeeklyResetPublicationAdmission(
                outcome: nil,
                pendingCandidate: input.pendingCandidate)
        }
        return CodexWeeklyResetPublicationAdmission(
            outcome: input.publicationInitialOutcome,
            pendingCandidate: nil)
    }

    private nonisolated static func codexCandidateAfterPreservedInitial(
        _ candidate: CodexWeeklyResetPublicationCandidate?,
        previousSnapshot: UsageSnapshot?,
        initialSnapshot: UsageSnapshot,
        initialResult: ProviderFetchResult,
        observedAt: Date) -> CodexWeeklyResetPublicationCandidate?
    {
        guard let candidate else { return nil }
        let decision = CodexWeeklyResetConfirmation.delayedCandidateDecision(
            previous: previousSnapshot,
            candidate: candidate,
            current: initialSnapshot,
            currentIsExactOAuth: Self.isExactCodexOAuthResult(initialResult),
            observedAt: observedAt)
        return decision == .discardCandidate ? nil : candidate
    }

    private nonisolated static func logCodexWeeklyResetInitialDecision(
        _ decision: CodexWeeklyResetConfirmation.InitialDecision,
        previousSnapshot: UsageSnapshot?,
        missingWindowBackfillSnapshot: UsageSnapshot?,
        publicationBaseline: UsageSnapshot?,
        initialSnapshot: UsageSnapshot)
    {
        guard decision != .publishInitial else { return }
        self.logCodexWeeklyResetPublicationDecision(
            stage: "initial",
            decision: String(describing: decision),
            trace: CodexWeeklyResetPublicationTrace(
                previousSnapshot: previousSnapshot,
                missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
                publicationBaseline: publicationBaseline,
                initialSnapshot: initialSnapshot,
                confirmationSnapshot: nil))
    }

    private nonisolated static func isExactCodexOAuthResult(_ result: ProviderFetchResult) -> Bool {
        guard case .oauth = result.strategyKind else { return false }
        return result.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "oauth"
            && result.usage.scoped(to: .codex).dataConfidence == .exact
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
