import CodexBarCore
import Foundation

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

    private static let resetEquivalenceToleranceSeconds: TimeInterval = 2 * 60
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
            let confirmsManualReset = Self.confirmsManualResetCreditConsumption(
                previous: previous,
                initial: initial,
                confirmation: confirmation)
            if confirmation.updatedAt < previousBoundary.addingTimeInterval(-2 * 60),
               !confirmsManualReset
            {
                return .preservePrevious
            }
            guard initialBoundary.timeIntervalSince(previousBoundary) >= Self.resetEquivalenceToleranceSeconds,
                  confirmationBoundary.timeIntervalSince(previousBoundary) >= Self.resetEquivalenceToleranceSeconds
            else {
                return .preservePrevious
            }
        }
        return .publishConfirmation
    }

    private static func confirmsManualResetCreditConsumption(
        previous: UsageSnapshot,
        initial: UsageSnapshot,
        confirmation: UsageSnapshot) -> Bool
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
            return false
        }
        let previouslyAvailableCredits = previousCredits.availableCredits(at: previousCredits.updatedAt)
        // An explicitly observed zero-credit inventory means there was no manual reset credit to
        // consume. Requiring consumption proof here would deadlock: the two consistent observations
        // (initial + confirmation) are the only signal a server-side early reset has, so trust them.
        // A nil/unknown previous inventory stays conservative and keeps demanding consumption proof.
        guard !previouslyAvailableCredits.isEmpty else {
            return previousCredits.availableCount == 0
        }
        return previouslyAvailableCredits.contains { previousCredit in
            Self.inventoryConfirmsConsumption(
                previousCredit: previousCredit,
                current: initialCredits,
                previousAvailableCount: previousCredits.availableCount) &&
                Self.inventoryConfirmsConsumption(
                    previousCredit: previousCredit,
                    current: confirmationCredits,
                    previousAvailableCount: previousCredits.availableCount)
        }
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
