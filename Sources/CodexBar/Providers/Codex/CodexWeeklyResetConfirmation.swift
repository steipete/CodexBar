import CodexBarCore
import Foundation

struct CodexWeeklyResetPublicationCandidate: Codable, Sendable {
    static let currentEvidenceVersion = 1

    let evidenceVersion: Int
    let firstObservedAt: Date
    let snapshot: UsageSnapshot

    init(firstObservedAt: Date, snapshot: UsageSnapshot) {
        self.evidenceVersion = Self.currentEvidenceVersion
        self.firstObservedAt = firstObservedAt
        self.snapshot = snapshot
    }
}

struct CodexWeeklyResetConfirmation: Sendable {
    enum InitialDecision: Equatable, Sendable {
        case publishInitial
        case requiresConfirmation
        case preservePrevious
    }

    enum ConfirmationDecision: Equatable, Sendable {
        case publishConfirmation
        case preservePrevious
    }

    enum DelayedCandidateDecision: Equatable, Sendable {
        case publishCurrent
        case retainCandidate
        case discardCandidate
    }

    struct SourceEvidence: Equatable, Sendable {
        static let allExactOAuth = Self(
            previousIsExactOAuth: true,
            initialIsExactOAuth: true,
            confirmationIsExactOAuth: true)

        let previousIsExactOAuth: Bool
        let initialIsExactOAuth: Bool
        let confirmationIsExactOAuth: Bool
    }

    private struct AvailableCreditIdentity: Equatable {
        let id: String
        let resetType: String
        let status: String
        let expiresAt: Date?
    }

    private enum ResetCreditEvidence: Equatable {
        case none
        case consumed
        case noAvailableCredits
    }

    private static let resetEquivalenceToleranceSeconds: TimeInterval = 2 * 60
    private static let stableUnchangedBoundaryToleranceSeconds: TimeInterval = 1
    private static let delayedCandidateMinimumAge: TimeInterval = 60
    private static let delayedCandidateMaximumAge: TimeInterval = 30 * 60
    private static let resetThreshold = 1.0

    static func initialDecision(
        previous: UsageSnapshot?,
        initial: UsageSnapshot) -> InitialDecision
    {
        guard self.isFinite(initial.updatedAt) else { return .preservePrevious }
        guard let previous else {
            guard let initialWeekly = CodexConsumerProjection.sourceRateWindow(
                for: .weekly,
                snapshot: initial)
            else {
                return .publishInitial
            }
            return self.initialDecisionWithoutWeeklyBaseline(
                initialWeekly: initialWeekly,
                capturedAt: initial.updatedAt)
        }
        guard Self.isFinite(previous.updatedAt), initial.updatedAt > previous.updatedAt else {
            return .preservePrevious
        }

        guard let previousWeekly = CodexConsumerProjection.sourceRateWindow(
            for: .weekly,
            snapshot: previous)
        else {
            guard let initialWeekly = CodexConsumerProjection.sourceRateWindow(
                for: .weekly,
                snapshot: initial)
            else {
                return .publishInitial
            }
            return self.initialDecisionWithoutWeeklyBaseline(
                initialWeekly: initialWeekly,
                capturedAt: initial.updatedAt)
        }
        guard previousWeekly.usedPercent.isFinite else {
            return .preservePrevious
        }
        // A source can legitimately omit the weekly lane and rely on the existing
        // reset-window backfill path. Only gate an explicit weekly observation.
        guard let initialWeekly = CodexConsumerProjection.sourceRateWindow(
            for: .weekly,
            snapshot: initial)
        else {
            return .preservePrevious
        }
        guard initialWeekly.usedPercent.isFinite else { return .preservePrevious }
        let previousBoundary = Self.finiteResetBoundary(previousWeekly)
        let initialBoundary = Self.finiteResetBoundary(initialWeekly)
        if initialWeekly.resetsAt != nil,
           Self.validResetBoundary(initialWeekly, capturedAt: initial.updatedAt) == nil
        {
            return .preservePrevious
        }
        if let previousBoundary, let initialBoundary,
           initialBoundary.timeIntervalSince(previousBoundary) < -Self.resetEquivalenceToleranceSeconds
        {
            return .preservePrevious
        }

        guard previousWeekly.usedPercent > Self.resetThreshold,
              initialWeekly.usedPercent <= Self.resetThreshold
        else {
            return .publishInitial
        }
        guard Self.validResetBoundary(initialWeekly, capturedAt: initial.updatedAt) != nil else {
            return .preservePrevious
        }
        return .requiresConfirmation
    }

    static func confirmationDecision(
        previous: UsageSnapshot?,
        previousEvidence: UsageSnapshot? = nil,
        initial: UsageSnapshot,
        confirmation: UsageSnapshot) -> ConfirmationDecision
    {
        guard previous.map({ self.isFinite($0.updatedAt) }) ?? true,
              self.isFinite(initial.updatedAt),
              self.isFinite(confirmation.updatedAt),
              confirmation.updatedAt > initial.updatedAt,
              let initialWeekly = CodexConsumerProjection.sourceRateWindow(
                  for: .weekly,
                  snapshot: initial),
              let confirmationWeekly = CodexConsumerProjection.sourceRateWindow(
                  for: .weekly,
                  snapshot: confirmation),
              initialWeekly.usedPercent.isFinite,
              confirmationWeekly.usedPercent.isFinite
        else {
            return .preservePrevious
        }
        let previousWeekly = CodexConsumerProjection.sourceRateWindow(
            for: .weekly,
            snapshot: previous)
        guard previousWeekly?.usedPercent.isFinite ?? true else { return .preservePrevious }
        let previousBoundary = previousWeekly.flatMap(Self.finiteResetBoundary)
        let confirmationBoundary = Self.finiteResetBoundary(confirmationWeekly)
        if confirmationWeekly.resetsAt != nil,
           Self.validResetBoundary(confirmationWeekly, capturedAt: confirmation.updatedAt) == nil
        {
            return .preservePrevious
        }
        if let previousBoundary, let confirmationBoundary,
           confirmationBoundary.timeIntervalSince(previousBoundary) < -Self.resetEquivalenceToleranceSeconds
        {
            return .preservePrevious
        }

        if confirmationWeekly.usedPercent > Self.resetThreshold {
            return .publishConfirmation
        }

        guard initialWeekly.usedPercent <= Self.resetThreshold,
              let initialBoundary = Self.validResetBoundary(initialWeekly, capturedAt: initial.updatedAt),
              let confirmationBoundary = Self.validResetBoundary(
                  confirmationWeekly,
                  capturedAt: confirmation.updatedAt),
              abs(initialBoundary.timeIntervalSince(confirmationBoundary))
              < Self.resetEquivalenceToleranceSeconds
        else {
            return .preservePrevious
        }
        if let previous,
           let previousWeekly,
           let previousBoundary = Self.validResetBoundary(
               previousWeekly,
               capturedAt: previous.updatedAt)
        {
            let evidencePrevious = previousEvidence ?? previous
            let resetCreditEvidence = Self.resetCreditEvidence(
                previous: evidencePrevious,
                initial: initial,
                confirmation: confirmation)
            let confirmsManualReset = resetCreditEvidence != .none
            if confirmation.updatedAt < previousBoundary.addingTimeInterval(-2 * 60),
               !confirmsManualReset
            {
                return .preservePrevious
            }
            guard initialBoundary.timeIntervalSince(previousBoundary) >= Self.resetEquivalenceToleranceSeconds,
                  confirmationBoundary.timeIntervalSince(previousBoundary) >= Self.resetEquivalenceToleranceSeconds
            else {
                return resetCreditEvidence == .consumed ? .publishConfirmation : .preservePrevious
            }
        }
        return .publishConfirmation
    }

    static func makeDelayedCandidate(
        previous: UsageSnapshot?,
        initial: UsageSnapshot,
        confirmation: UsageSnapshot,
        sourceEvidence: SourceEvidence) -> CodexWeeklyResetPublicationCandidate?
    {
        guard sourceEvidence.previousIsExactOAuth,
              sourceEvidence.initialIsExactOAuth,
              sourceEvidence.confirmationIsExactOAuth,
              let previous,
              previous.dataConfidence == .exact,
              initial.dataConfidence == .exact,
              confirmation.dataConfidence == .exact,
              isFinite(previous.updatedAt),
              isFinite(initial.updatedAt),
              isFinite(confirmation.updatedAt),
              initial.updatedAt > previous.updatedAt,
              confirmation.updatedAt > initial.updatedAt,
              let previousWeekly = CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: previous),
              let initialWeekly = CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: initial),
              let confirmationWeekly = CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: confirmation),
              previousWeekly.usedPercent.isFinite,
              previousWeekly.usedPercent > Self.resetThreshold,
              initialWeekly.usedPercent.isFinite,
              initialWeekly.usedPercent <= Self.resetThreshold,
              confirmationWeekly.usedPercent.isFinite,
              confirmationWeekly.usedPercent <= Self.resetThreshold,
              let previousBoundary = validResetBoundary(previousWeekly, capturedAt: previous.updatedAt),
              let initialBoundary = validResetBoundary(initialWeekly, capturedAt: initial.updatedAt),
              let confirmationBoundary = validResetBoundary(
                  confirmationWeekly,
                  capturedAt: confirmation.updatedAt),
              abs(initialBoundary.timeIntervalSince(confirmationBoundary))
              < resetEquivalenceToleranceSeconds,
              isSupportedDelayedBoundary(previous: previousBoundary, current: initialBoundary),
              isSupportedDelayedBoundary(previous: previousBoundary, current: confirmationBoundary),
              haveCompatibleAccountIdentities(previous, initial, confirmation),
              haveCompatiblePlans(previous, initial, confirmation),
              haveStablePositiveCreditInventory(previous, initial, confirmation)
        else {
            return nil
        }
        return CodexWeeklyResetPublicationCandidate(
            firstObservedAt: initial.updatedAt,
            snapshot: confirmation)
    }

    static func delayedCandidateDecision(
        previous: UsageSnapshot?,
        candidate: CodexWeeklyResetPublicationCandidate,
        current: UsageSnapshot,
        currentIsExactOAuth: Bool) -> DelayedCandidateDecision
    {
        guard candidate.evidenceVersion == CodexWeeklyResetPublicationCandidate.currentEvidenceVersion else {
            return .discardCandidate
        }
        guard self.isFinite(candidate.firstObservedAt),
              self.isFinite(candidate.snapshot.updatedAt),
              self.isFinite(current.updatedAt)
        else {
            return .discardCandidate
        }
        guard current.updatedAt > candidate.snapshot.updatedAt else { return .retainCandidate }
        let age = current.updatedAt.timeIntervalSince(candidate.firstObservedAt)
        guard age >= 0, age <= Self.delayedCandidateMaximumAge else { return .discardCandidate }
        guard currentIsExactOAuth,
              let previous,
              previous.dataConfidence == .exact,
              candidate.snapshot.dataConfidence == .exact,
              current.dataConfidence == .exact,
              let previousWeekly = CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: previous),
              let candidateWeekly = CodexConsumerProjection.sourceRateWindow(
                  for: .weekly,
                  snapshot: candidate.snapshot),
              let currentWeekly = CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: current),
              previousWeekly.usedPercent.isFinite,
              previousWeekly.usedPercent > Self.resetThreshold,
              candidateWeekly.usedPercent.isFinite,
              candidateWeekly.usedPercent <= Self.resetThreshold,
              currentWeekly.usedPercent.isFinite,
              currentWeekly.usedPercent <= Self.resetThreshold,
              let previousBoundary = Self.validResetBoundary(previousWeekly, capturedAt: previous.updatedAt),
              let candidateBoundary = Self.validResetBoundary(
                  candidateWeekly,
                  capturedAt: candidate.snapshot.updatedAt),
              let currentBoundary = Self.validResetBoundary(currentWeekly, capturedAt: current.updatedAt),
              abs(candidateBoundary.timeIntervalSince(currentBoundary))
              < Self.resetEquivalenceToleranceSeconds,
              Self.isSupportedDelayedBoundary(previous: previousBoundary, current: candidateBoundary),
              Self.isSupportedDelayedBoundary(previous: previousBoundary, current: currentBoundary),
              Self.haveCompatibleAccountIdentities(previous, candidate.snapshot, current),
              Self.haveCompatiblePlans(previous, candidate.snapshot, current),
              Self.haveStablePositiveCreditInventory(previous, candidate.snapshot, current)
        else {
            return .discardCandidate
        }
        return age >= Self.delayedCandidateMinimumAge ? .publishCurrent : .retainCandidate
    }

    static func shouldRetainDelayedCandidate(
        _ candidate: CodexWeeklyResetPublicationCandidate,
        observedAt: Date) -> Bool
    {
        guard candidate.evidenceVersion == CodexWeeklyResetPublicationCandidate.currentEvidenceVersion,
              self.isFinite(candidate.firstObservedAt),
              self.isFinite(candidate.snapshot.updatedAt),
              self.isFinite(observedAt)
        else {
            return false
        }
        guard observedAt > candidate.snapshot.updatedAt else { return true }
        let age = observedAt.timeIntervalSince(candidate.firstObservedAt)
        return age >= 0 && age <= self.delayedCandidateMaximumAge
    }

    private static func haveCompatibleAccountIdentities(_ snapshots: UsageSnapshot...) -> Bool {
        let identities = snapshots.map { CodexIdentityResolver.normalizeEmail($0.accountEmail(for: .codex)) }
        guard let first = identities.compactMap(\.self).first else { return false }
        return identities.allSatisfy { $0 == first }
    }

    private static func haveCompatiblePlans(_ snapshots: UsageSnapshot...) -> Bool {
        // Codex exposes the subscription tier through loginMethod, so it is the plan identity here.
        let plans = snapshots.map { snapshot in
            snapshot.loginMethod(for: .codex)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        guard let first = plans.compactMap(\.self).first else { return false }
        return plans.allSatisfy { $0 == first }
    }

    private static func haveStablePositiveCreditInventory(_ snapshots: UsageSnapshot...) -> Bool {
        let creditSnapshots = snapshots.compactMap(\.codexResetCredits)
        guard creditSnapshots.count == snapshots.count,
              creditSnapshots.allSatisfy({ Self.isFinite($0.updatedAt) }),
              zip(creditSnapshots, creditSnapshots.dropFirst()).allSatisfy({ pair in
                  pair.1.updatedAt >= pair.0.updatedAt
              })
        else {
            return false
        }
        let inventories = creditSnapshots.map { credits -> [AvailableCreditIdentity]? in
            let available = credits.availableCredits(at: credits.updatedAt)
            guard credits.availableCount > 0, available.count == credits.availableCount else { return nil }
            return available.map {
                AvailableCreditIdentity(
                    id: $0.id,
                    resetType: $0.resetType,
                    status: $0.status.rawValue,
                    expiresAt: $0.expiresAt)
            }.sorted { lhs, rhs in
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                if lhs.resetType != rhs.resetType { return lhs.resetType < rhs.resetType }
                if lhs.status != rhs.status { return lhs.status < rhs.status }
                return (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
            }
        }
        guard let firstInventory = inventories.first,
              let first = firstInventory
        else {
            return false
        }
        return inventories.allSatisfy { $0 == first }
    }

    private static func isSupportedDelayedBoundary(previous: Date, current: Date) -> Bool {
        abs(current.timeIntervalSince(previous)) < self.stableUnchangedBoundaryToleranceSeconds
            || current.timeIntervalSince(previous) >= self.resetEquivalenceToleranceSeconds
    }

    private static func resetCreditEvidence(
        previous: UsageSnapshot,
        initial: UsageSnapshot,
        confirmation: UsageSnapshot) -> ResetCreditEvidence
    {
        guard let previousCredits = previous.codexResetCredits,
              let initialCredits = initial.codexResetCredits,
              let confirmationCredits = confirmation.codexResetCredits,
              self.isFinite(previousCredits.updatedAt),
              self.isFinite(initialCredits.updatedAt),
              self.isFinite(confirmationCredits.updatedAt),
              initialCredits.updatedAt >= previousCredits.updatedAt,
              confirmationCredits.updatedAt >= initialCredits.updatedAt
        else {
            return .none
        }
        let previouslyAvailableCredits = previousCredits.availableCredits(at: previousCredits.updatedAt)
        // An explicitly observed zero-credit inventory means there was no manual reset credit to
        // consume. Requiring consumption proof here would deadlock: the two consistent observations
        // (initial + confirmation) are the only signal a server-side early reset has, so trust them.
        // A nil/unknown previous inventory stays conservative and keeps demanding consumption proof.
        guard !previouslyAvailableCredits.isEmpty else {
            return previousCredits.availableCount == 0 ? .noAvailableCredits : .none
        }
        let consumed = previouslyAvailableCredits.contains { previousCredit in
            Self.inventoryConfirmsConsumption(
                previousCredit: previousCredit,
                current: initialCredits,
                previousAvailableCount: previousCredits.availableCount) &&
                Self.inventoryConfirmsConsumption(
                    previousCredit: previousCredit,
                    current: confirmationCredits,
                    previousAvailableCount: previousCredits.availableCount)
        }
        return consumed ? .consumed : .none
    }

    private static func inventoryConfirmsConsumption(
        previousCredit: CodexRateLimitResetCredit,
        current: CodexRateLimitResetCreditsSnapshot,
        previousAvailableCount: Int) -> Bool
    {
        if let credit = current.credits.first(where: { $0.id == previousCredit.id }) {
            return credit.status == .redeeming || credit.status == .redeemed
        }
        // A credit can disappear because it expired. Only treat omission as consumption while
        // the previously available credit would still be valid at this inventory timestamp.
        guard previousCredit.expiresAt.map({ $0 > current.updatedAt }) ?? true else { return false }
        // The live provider omits a consumed credit instead of retaining a redeemed row, so the
        // successful inventory's aggregate count must also corroborate the disappearance.
        return current.availableCount < previousAvailableCount
    }

    private static func initialDecisionWithoutWeeklyBaseline(
        initialWeekly: RateWindow,
        capturedAt: Date) -> InitialDecision
    {
        guard initialWeekly.usedPercent.isFinite else { return .preservePrevious }
        if initialWeekly.resetsAt != nil,
           self.validResetBoundary(initialWeekly, capturedAt: capturedAt) == nil
        {
            return .preservePrevious
        }
        guard initialWeekly.usedPercent <= self.resetThreshold else { return .publishInitial }
        return self.validResetBoundary(initialWeekly, capturedAt: capturedAt) == nil
            ? .preservePrevious
            : .requiresConfirmation
    }

    private static func finiteResetBoundary(_ window: RateWindow) -> Date? {
        guard let boundary = window.resetsAt, isFinite(boundary) else { return nil }
        return boundary
    }

    private static func validResetBoundary(_ window: RateWindow, capturedAt: Date) -> Date? {
        guard let boundary = self.finiteResetBoundary(window), boundary > capturedAt else { return nil }
        return boundary
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}
