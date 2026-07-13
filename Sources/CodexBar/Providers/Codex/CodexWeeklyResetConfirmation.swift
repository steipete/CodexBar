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
            guard initialBoundary.timeIntervalSince(previousBoundary) >= Self.resetEquivalenceToleranceSeconds,
                  confirmationBoundary.timeIntervalSince(previousBoundary) >= Self.resetEquivalenceToleranceSeconds
            else {
                return .preservePrevious
            }
        }
        return .publishConfirmation
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
