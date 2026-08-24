import CodexBarCore
import Foundation

extension UsageStore {
    private nonisolated static let limitResetThreshold = 1.0
    private nonisolated static let claudeWeeklyRecoveryObservationCount = 2
    // A newly advanced weekly boundary is strong reset evidence. Allow a modest amount of usage
    // so a reset is not missed when the first post-rollover sample arrives after the user resumed work.
    private nonisolated static let codexWeeklyAdvancedBoundaryResetThreshold = 5.0
    private nonisolated static let codexWeeklyResetCandidateConfirmationThreshold = 5.0
    private nonisolated static let codexWeeklyResetCandidateMinimumAge: TimeInterval = 60
    private nonisolated static let codexWeeklyResetCandidateMaximumAge: TimeInterval = 30 * 60
    private nonisolated static let codexWeeklyResetCandidateBoundaryToleranceSeconds: TimeInterval = 1

    struct LimitResetDetectorState: Codable, Equatable {
        static let currentCodexWeeklyEvidenceVersion = 2

        let wasAboveThreshold: Bool
        let wasAboveCodexWeeklyCandidateThreshold: Bool
        let lastObservedAt: Date
        let sourceRawValue: String?
        var resetBoundary: Date?
        var recoveryAboveThresholdCount: Int?
        /// Identity-less Claude CLI samples share one detector key and can be transient.
        /// Require a second low sample before celebrating an apparent reset from that key.
        var pendingLowConfirmation: Bool
        var pendingLowObservedAt: Date?
        var lastPostedResetBoundary: Date?
        var planRawValue: String?
        /// Distinguishes states that carry the Codex plan/dedup evidence added with delayed reset confirmation.
        var codexWeeklyEvidenceVersion: Int?

        init(
            wasAboveThreshold: Bool,
            wasAboveCodexWeeklyCandidateThreshold: Bool = false,
            lastObservedAt: Date,
            sourceRawValue: String?,
            resetBoundary: Date? = nil,
            recoveryAboveThresholdCount: Int? = nil,
            pendingLowConfirmation: Bool = false,
            pendingLowObservedAt: Date? = nil,
            lastPostedResetBoundary: Date? = nil,
            planRawValue: String? = nil,
            codexWeeklyEvidenceVersion: Int? = Self.currentCodexWeeklyEvidenceVersion)
        {
            self.wasAboveThreshold = wasAboveThreshold
            self.wasAboveCodexWeeklyCandidateThreshold = wasAboveCodexWeeklyCandidateThreshold
            self.lastObservedAt = lastObservedAt
            self.sourceRawValue = sourceRawValue
            self.resetBoundary = resetBoundary
            self.recoveryAboveThresholdCount = recoveryAboveThresholdCount
            self.pendingLowConfirmation = pendingLowConfirmation
            self.pendingLowObservedAt = pendingLowObservedAt
            self.lastPostedResetBoundary = lastPostedResetBoundary
            self.planRawValue = planRawValue
            self.codexWeeklyEvidenceVersion = codexWeeklyEvidenceVersion
        }

        private enum CodingKeys: String, CodingKey {
            case wasAboveThreshold
            case wasAboveCodexWeeklyCandidateThreshold
            case lastObservedAt
            case sourceRawValue
            case resetBoundary
            case recoveryAboveThresholdCount
            case pendingLowConfirmation
            case pendingLowObservedAt
            case lastPostedResetBoundary
            case planRawValue
            case codexWeeklyEvidenceVersion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.wasAboveThreshold = try container.decode(Bool.self, forKey: .wasAboveThreshold)
            self.wasAboveCodexWeeklyCandidateThreshold = try container.decodeIfPresent(
                Bool.self,
                forKey: .wasAboveCodexWeeklyCandidateThreshold) ?? false
            self.lastObservedAt = try container.decode(Date.self, forKey: .lastObservedAt)
            self.sourceRawValue = try container.decodeIfPresent(String.self, forKey: .sourceRawValue)
            self.resetBoundary = try container.decodeIfPresent(Date.self, forKey: .resetBoundary)
            self.recoveryAboveThresholdCount = try container.decodeIfPresent(
                Int.self,
                forKey: .recoveryAboveThresholdCount)
            self.pendingLowConfirmation = try container.decodeIfPresent(
                Bool.self,
                forKey: .pendingLowConfirmation) ?? false
            self.pendingLowObservedAt = try container.decodeIfPresent(Date.self, forKey: .pendingLowObservedAt)
            self.lastPostedResetBoundary = try container.decodeIfPresent(
                Date.self,
                forKey: .lastPostedResetBoundary)
            self.planRawValue = try container.decodeIfPresent(String.self, forKey: .planRawValue)
            self.codexWeeklyEvidenceVersion = try container.decodeIfPresent(
                Int.self,
                forKey: .codexWeeklyEvidenceVersion)
        }
    }

    struct LimitResetDetectionContext {
        let provider: UsageProvider
        let account: ProviderTokenAccount?
        let snapshot: UsageSnapshot
        let accountKey: String?
        let capturedAt: Date
        let codexLimitResetOwnerKey: CodexLimitResetOwnerKey?
    }

    struct LimitResetObservation {
        let usedPercent: Double
        let observedAt: Date
        let resetBoundary: Date?
        let source: SessionQuotaWindowSource?
    }

    struct LimitResetDetectionDescriptor {
        let seriesName: PlanUtilizationSeriesName
        let defaultsKey: String
        let resetKind: String
    }

    private struct LimitResetDetectorTransitionInput {
        let provider: UsageProvider
        let snapshot: UsageSnapshot
        let seriesName: PlanUtilizationSeriesName
        let observation: LimitResetObservation
        let previousState: LimitResetDetectorState?
        let requiresLowConfirmation: Bool
    }

    private struct LimitResetDetectorTransition {
        let state: LimitResetDetectorState
        let shouldPost: Bool
        let claudeWeeklyRecoveryPending: Bool
        let nextRecoveryCount: Int
    }

    private struct CodexWeeklyResetDecisionInput {
        let previousState: LimitResetDetectorState?
        let observation: LimitResetObservation
        let planChanged: Bool
        let planMatchesPrevious: Bool
        let sourceChanged: Bool
        let resetBoundaryAllowsPost: Bool
    }

    private struct CodexWeeklyResetDecision {
        let shouldStartCandidate: Bool
        let retainingCandidate: Bool
        let expiredCandidate: Bool
        let shouldPost: Bool

        static let inactive = Self(
            shouldStartCandidate: false,
            retainingCandidate: false,
            expiredCandidate: false,
            shouldPost: false)
    }

    func postLimitResetCelebrationIfNeeded(
        states: inout [String: LimitResetDetectorState],
        context: LimitResetDetectionContext,
        descriptor: LimitResetDetectionDescriptor,
        observation: LimitResetObservation?)
    {
        guard let observation else { return }

        guard let accountIdentifier = self.limitResetAccountIdentifier(
            provider: context.provider,
            account: context.account,
            snapshot: context.snapshot,
            accountKey: context.accountKey,
            codexLimitResetOwnerKey: context.codexLimitResetOwnerKey)
        else {
            return
        }
        let detectorKey = Self.limitResetDetectorStateKey(
            provider: context.provider,
            accountIdentifier: accountIdentifier)
        let requiresLowConfirmation = context.provider == .claude
            && accountIdentifier == context.provider.rawValue
        let currentUsed = observation.usedPercent
        let currentObservedAt = observation.observedAt
        if let existingState = states[detectorKey],
           currentObservedAt <= existingState.lastObservedAt
        {
            return
        }

        let previousState = states[detectorKey]
        let transition = Self.limitResetDetectorTransition(
            input: LimitResetDetectorTransitionInput(
                provider: context.provider,
                snapshot: context.snapshot,
                seriesName: descriptor.seriesName,
                observation: observation,
                previousState: previousState,
                requiresLowConfirmation: requiresLowConfirmation))
        states[detectorKey] = transition.state
        self.persistLimitResetDetectorStates(
            states,
            defaultsKey: descriptor.defaultsKey,
            logName: descriptor.resetKind)

        if transition.claudeWeeklyRecoveryPending, currentUsed > Self.limitResetThreshold {
            CodexBarLog.logger(LogCategories.confetti).debug(
                "Confirming Claude weekly usage recovery after celebration",
                metadata: [
                    "accountIdentifier": accountIdentifier,
                    "confirmationCount": String(transition.nextRecoveryCount),
                    "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
                ])
        }

        guard transition.shouldPost else { return }
        let accountLabel = self.limitResetAccountLabel(
            provider: context.provider,
            account: context.account,
            snapshot: context.snapshot)

        CodexBarLog.logger(LogCategories.confetti).info(
            "\(descriptor.resetKind.capitalized) limit reset",
            metadata: [
                "provider": context.provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "accountLabel": accountLabel ?? "",
                "resetKind": descriptor.resetKind,
                "usedPercent": String(format: "%.2f", currentUsed),
                "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
            ])
        switch descriptor.seriesName {
        case .session:
            self.emitQuotaResetHook(
                provider: context.provider,
                window: .session,
                usedPercent: currentUsed,
                accountLabel: accountLabel)
            let event = SessionLimitResetEvent(
                provider: context.provider,
                accountIdentifier: accountIdentifier,
                accountLabel: accountLabel,
                usedPercent: currentUsed)
            NotificationCenter.default.post(name: .codexbarSessionLimitReset, object: event)
        case .weekly:
            self.emitQuotaResetHook(
                provider: context.provider,
                window: .weekly,
                usedPercent: currentUsed,
                accountLabel: accountLabel)
            let event = WeeklyLimitResetEvent(
                provider: context.provider,
                accountIdentifier: accountIdentifier,
                accountLabel: accountLabel,
                usedPercent: currentUsed)
            NotificationCenter.default.post(name: .codexbarWeeklyLimitReset, object: event)
        default:
            return
        }
    }

    private nonisolated static func limitResetDetectorTransition(
        input: LimitResetDetectorTransitionInput) -> LimitResetDetectorTransition
    {
        let observation = input.observation
        let previousState = input.previousState
        let currentUsed = observation.usedPercent
        let currentObservedAt = observation.observedAt
        let wasAboveThreshold = currentUsed > self.limitResetThreshold
        let wasAboveCodexWeeklyCandidateThreshold = currentUsed > self.codexWeeklyResetCandidateConfirmationThreshold
        let isClaudeWeekly = input.provider == .claude && input.seriesName == .weekly
        let isCodexWeekly = input.provider == .codex && input.seriesName == .weekly
        let claudeWeeklyRecoveryPending = isClaudeWeekly
            && previousState?.recoveryAboveThresholdCount != nil
        let planRawValue = isCodexWeekly ? self.limitResetPlanIdentifier(input.snapshot) : nil
        let planChanged = isCodexWeekly
            && previousState?.planRawValue != nil
            && previousState?.planRawValue != planRawValue
        let planMatchesPrevious = isCodexWeekly
            && planRawValue != nil
            && previousState?.planRawValue == planRawValue
        let sourceRawValue = observation.source?.rawValue
        let sourceChanged = input.seriesName == .session
            && previousState?.sourceRawValue != nil
            && previousState?.sourceRawValue != sourceRawValue
        let resetBoundaryAllowsPost = self.limitResetBoundaryAllowsPost(input: input)
        let crossedBelowThreshold = !sourceChanged
            && previousState?.wasAboveThreshold == true
            && !wasAboveThreshold
        let confirmingLowSample = !sourceChanged
            && previousState?.pendingLowConfirmation == true
            && !wasAboveThreshold
        let codexDecision = isCodexWeekly
            ? self.codexWeeklyResetDecision(
                input: CodexWeeklyResetDecisionInput(
                    previousState: previousState,
                    observation: observation,
                    planChanged: planChanged,
                    planMatchesPrevious: planMatchesPrevious,
                    sourceChanged: sourceChanged,
                    resetBoundaryAllowsPost: resetBoundaryAllowsPost))
            : .inactive
        let shouldPost = if input.requiresLowConfirmation {
            confirmingLowSample && !claudeWeeklyRecoveryPending
        } else if isCodexWeekly {
            codexDecision.shouldPost
        } else {
            crossedBelowThreshold && resetBoundaryAllowsPost && !claudeWeeklyRecoveryPending
        }
        let suppressedGuardedCrossing = crossedBelowThreshold && !resetBoundaryAllowsPost
        let shouldAwaitLowConfirmation = input.requiresLowConfirmation
            && crossedBelowThreshold
            && !confirmingLowSample
            && resetBoundaryAllowsPost
            && !claudeWeeklyRecoveryPending
        // Sessions retain the last non-regressed boundary on every guarded sample. Codex weekly crossings
        // adopt a newly appearing boundary so a later genuine advance can still trigger once.
        let shouldPreserveBoundary = !sourceChanged
            && !resetBoundaryAllowsPost
            && (input.seriesName == .session || previousState?.resetBoundary != nil)
        let shouldPreserveBaseline = suppressedGuardedCrossing
            && !planChanged
            && !codexDecision.expiredCandidate
        let previousRecoveryCount = previousState?.recoveryAboveThresholdCount ?? 0
        let nextRecoveryCount = if claudeWeeklyRecoveryPending {
            wasAboveThreshold ? previousRecoveryCount + 1 : 0
        } else {
            0
        }
        let claudeWeeklyRecoveryConfirmed = claudeWeeklyRecoveryPending
            && nextRecoveryCount >= self.claudeWeeklyRecoveryObservationCount
        let nextWasAboveThreshold = if shouldPost {
            false
        } else if claudeWeeklyRecoveryPending {
            claudeWeeklyRecoveryConfirmed
        } else if codexDecision.expiredCandidate || planChanged {
            isCodexWeekly
                ? currentUsed > self.codexWeeklyResetCandidateConfirmationThreshold
                : wasAboveThreshold
        } else if shouldPreserveBaseline || shouldAwaitLowConfirmation {
            true
        } else {
            wasAboveThreshold
        }
        let nextWasAboveCodexWeeklyCandidateThreshold = if isCodexWeekly {
            if shouldPost {
                false
            } else if shouldPreserveBaseline {
                previousState?.wasAboveCodexWeeklyCandidateThreshold == true
            } else {
                wasAboveCodexWeeklyCandidateThreshold
            }
        } else {
            false
        }
        let persistedRecoveryCount: Int? = if shouldPost {
            0
        } else if claudeWeeklyRecoveryPending, !claudeWeeklyRecoveryConfirmed {
            nextRecoveryCount
        } else {
            nil
        }
        let pendingLowConfirmation = shouldAwaitLowConfirmation
            || codexDecision.shouldStartCandidate
            || codexDecision.retainingCandidate
        let pendingLowObservedAt: Date? = if codexDecision.shouldStartCandidate {
            currentObservedAt
        } else if codexDecision.retainingCandidate {
            previousState?.pendingLowObservedAt
        } else {
            nil
        }
        let lastPostedResetBoundary: Date? = if planChanged {
            nil
        } else if shouldPost {
            observation.resetBoundary
        } else {
            previousState?.lastPostedResetBoundary
        }
        let state = LimitResetDetectorState(
            // A transient zero must not erase the baseline needed to recognize the real reset that follows.
            wasAboveThreshold: nextWasAboveThreshold,
            wasAboveCodexWeeklyCandidateThreshold: nextWasAboveCodexWeeklyCandidateThreshold,
            lastObservedAt: currentObservedAt,
            sourceRawValue: sourceRawValue,
            resetBoundary: shouldPreserveBoundary ? previousState?.resetBoundary : observation.resetBoundary,
            recoveryAboveThresholdCount: persistedRecoveryCount,
            pendingLowConfirmation: pendingLowConfirmation,
            pendingLowObservedAt: pendingLowObservedAt,
            lastPostedResetBoundary: lastPostedResetBoundary,
            planRawValue: planRawValue)
        return LimitResetDetectorTransition(
            state: state,
            shouldPost: shouldPost,
            claudeWeeklyRecoveryPending: claudeWeeklyRecoveryPending,
            nextRecoveryCount: nextRecoveryCount)
    }

    private nonisolated static func codexWeeklyResetDecision(
        input: CodexWeeklyResetDecisionInput) -> CodexWeeklyResetDecision
    {
        let previousState = input.previousState
        let observation = input.observation
        let currentUsed = observation.usedPercent
        let currentObservedAt = observation.observedAt
        let boundaryMatchesPrevious = self.codexWeeklyResetCandidateBoundaryMatches(
            previousState?.resetBoundary,
            observation.resetBoundary)
        let boundaryAlreadyPosted = self.codexWeeklyResetCandidateBoundaryMatches(
            previousState?.lastPostedResetBoundary,
            observation.resetBoundary)
        let pendingCandidateAge = previousState?.pendingLowObservedAt.map {
            currentObservedAt.timeIntervalSince($0)
        }
        let pendingCandidateCompatible = previousState?.pendingLowConfirmation == true
            && input.planMatchesPrevious
            && boundaryMatchesPrevious
            && !boundaryAlreadyPosted
            && currentUsed <= self.codexWeeklyResetCandidateConfirmationThreshold
            && observation.resetBoundary.map { currentObservedAt < $0 } == true
            && pendingCandidateAge.map {
                $0 >= 0 && $0 <= self.codexWeeklyResetCandidateMaximumAge
            } == true
        let confirmingCandidate = pendingCandidateCompatible
            && pendingCandidateAge.map { $0 >= self.codexWeeklyResetCandidateMinimumAge } == true
        let retainingCandidate = pendingCandidateCompatible && !confirmingCandidate
        let expiredCandidate = previousState?.pendingLowConfirmation == true
            && !confirmingCandidate
            && !retainingCandidate
            && !input.resetBoundaryAllowsPost
        let crossedIntoCandidateResetRange = !input.sourceChanged
            && previousState?.wasAboveCodexWeeklyCandidateThreshold == true
            && currentUsed <= self.codexWeeklyResetCandidateConfirmationThreshold
        let shouldStartCandidate = previousState?.pendingLowConfirmation != true
            && input.planMatchesPrevious
            && crossedIntoCandidateResetRange
            && !input.resetBoundaryAllowsPost
            && boundaryMatchesPrevious
            && !boundaryAlreadyPosted
            && observation.resetBoundary.map { currentObservedAt < $0 } == true
        let crossedIntoAdvancedBoundaryResetRange = !input.sourceChanged
            && previousState?.wasAboveThreshold == true
            && currentUsed <= self.codexWeeklyAdvancedBoundaryResetThreshold
        let shouldPost = !input.planChanged
            && ((crossedIntoAdvancedBoundaryResetRange && input.resetBoundaryAllowsPost) || confirmingCandidate)
        return CodexWeeklyResetDecision(
            shouldStartCandidate: shouldStartCandidate,
            retainingCandidate: retainingCandidate,
            expiredCandidate: expiredCandidate,
            shouldPost: shouldPost)
    }

    private nonisolated static func limitResetBoundaryAllowsPost(
        input: LimitResetDetectorTransitionInput) -> Bool
    {
        if input.seriesName == .session {
            return self.limitResetBoundaryAdvanced(
                previous: input.previousState?.resetBoundary,
                current: input.observation.resetBoundary)
        }
        if input.provider == .codex, input.seriesName == .weekly {
            return self.limitResetBoundaryAdvanced(
                previous: input.previousState?.resetBoundary,
                current: input.observation.resetBoundary,
                requiresPreviousBoundary: true)
        }
        return true
    }

    private nonisolated static func limitResetPlanIdentifier(_ snapshot: UsageSnapshot) -> String? {
        // UsageSnapshot stores the Codex subscription tier in loginMethod.
        snapshot.loginMethod(for: .codex)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated static func codexWeeklyResetCandidateBoundaryMatches(
        _ lhs: Date?,
        _ rhs: Date?) -> Bool
    {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < self.codexWeeklyResetCandidateBoundaryToleranceSeconds
    }
}
