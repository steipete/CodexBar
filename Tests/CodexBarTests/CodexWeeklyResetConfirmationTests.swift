import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexWeeklyResetConfirmationTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let resetAt = Date(timeIntervalSince1970: 1_800_500_000)

    @Test
    func `ordinary observations publish while stale initial observations preserve`() {
        let previous = self.snapshot(offset: 0, weeklyUsed: 70, weeklyReset: self.resetAt)
        let previousWithoutWeekly = self.snapshot(offset: 0, weeklyUsed: nil, weeklyReset: nil)
        let newer = self.snapshot(offset: 1, weeklyUsed: 71, weeklyReset: self.resetAt)
        let stale = self.snapshot(offset: 0, weeklyUsed: 72, weeklyReset: self.resetAt)

        #expect(CodexWeeklyResetConfirmation.initialDecision(previous: nil, initial: newer) == .publishInitial)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previousWithoutWeekly, initial: newer)
                == .publishInitial)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: newer) == .publishInitial)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: stale) == .preservePrevious)
    }

    @Test
    func `first low observation requires matching confirmation without prior state`() {
        let reset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previousWithoutWeekly = self.snapshot(offset: 0, weeklyUsed: nil, weeklyReset: nil)
        let initial = self.snapshot(offset: 1, weeklyUsed: 0.2, weeklyReset: reset)
        let matching = self.snapshot(offset: 2, weeklyUsed: 0.7, weeklyReset: reset.addingTimeInterval(30))
        let rebound = self.snapshot(offset: 2, weeklyUsed: 42, weeklyReset: reset)

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: nil, initial: initial)
                == .requiresConfirmation)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(
                previous: previousWithoutWeekly,
                initial: initial)
                == .requiresConfirmation)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(
                previous: previousWithoutWeekly,
                initial: self.snapshot(offset: 1, weeklyUsed: 0.2, weeklyReset: nil))
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: nil,
                initial: initial,
                confirmation: matching)
                == .publishConfirmation)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: nil,
                initial: initial,
                confirmation: rebound)
                == .publishConfirmation)
    }

    @Test
    func `reset backfill follows semantic lanes when cached positions are swapped`() {
        let sessionReset = self.resetAt.addingTimeInterval(60 * 60)
        let weeklyReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let partial = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 9,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: self.capturedAt)
        let swappedCache = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 55,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 44,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            updatedAt: self.capturedAt.addingTimeInterval(-1))

        let backfilled = UsageStore.codexBackfillingResetWindows(partial, from: swappedCache)

        #expect(backfilled.primary?.usedPercent == 9)
        #expect(backfilled.primary?.windowMinutes == 300)
        #expect(backfilled.primary?.resetsAt == sessionReset)
        #expect(backfilled.secondary?.usedPercent == 55)
        #expect(backfilled.secondary?.windowMinutes == 10080)
        #expect(backfilled.secondary?.resetsAt == weeklyReset)
    }

    @Test
    func `semantic weekly lookup handles swapped snapshot lanes`() {
        let nextReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = self.snapshot(
            offset: 0,
            weeklyUsed: 50,
            weeklyReset: self.resetAt,
            weeklyInPrimary: true)
        let initial = self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: nextReset,
            weeklyInPrimary: true)
        let confirmation = self.snapshot(
            offset: 2,
            weeklyUsed: 0.5,
            weeklyReset: nextReset.addingTimeInterval(60),
            weeklyInPrimary: true)

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: initial)
                == .requiresConfirmation)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: confirmation)
                == .publishConfirmation)
    }

    @Test
    func `missing candidate weekly data and reset boundaries fail closed`() {
        let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let missingWeekly = self.snapshot(offset: 1, weeklyUsed: nil, weeklyReset: nil)
        let initialWithoutBoundary = self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: nil)

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: missingWeekly)
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: initialWithoutBoundary)
                == .preservePrevious)

        let initial = self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: self.resetAt.addingTimeInterval(7 * 24 * 60 * 60))
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: missingWeekly)
                == .preservePrevious)
    }

    @Test
    func `two valid lows establish a reset when the previous boundary is unavailable`() {
        let nextReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let initial = self.snapshot(offset: 1, weeklyUsed: 0.2, weeklyReset: nextReset)
        let confirmation = self.snapshot(
            offset: 2,
            weeklyUsed: 0.7,
            weeklyReset: nextReset.addingTimeInterval(30))
        let unavailablePreviousBoundaries: [Date?] = [
            nil,
            self.capturedAt.addingTimeInterval(-1),
            Date(timeIntervalSinceReferenceDate: .infinity),
        ]

        for previousBoundary in unavailablePreviousBoundaries {
            let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: previousBoundary)
            #expect(
                CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: initial)
                    == .requiresConfirmation)
            #expect(
                CodexWeeklyResetConfirmation.confirmationDecision(
                    previous: previous,
                    initial: initial,
                    confirmation: confirmation)
                    == .publishConfirmation)
        }
    }

    @Test
    func `first ordinary high accepts a missing boundary but rejects explicit invalid boundaries`() {
        let missingBoundary = self.snapshot(offset: 1, weeklyUsed: 42, weeklyReset: nil)
        let elapsedBoundary = self.snapshot(
            offset: 1,
            weeklyUsed: 42,
            weeklyReset: self.capturedAt)
        let nonfiniteBoundary = self.snapshot(
            offset: 1,
            weeklyUsed: 42,
            weeklyReset: Date(timeIntervalSinceReferenceDate: .infinity))

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: nil, initial: missingBoundary)
                == .publishInitial)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: nil, initial: elapsedBoundary)
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: nil, initial: nonfiniteBoundary)
                == .preservePrevious)
    }

    @Test
    func `newer rebound publishes instead of accepting the transient low`() {
        let nextReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let initial = self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: nextReset)
        let confirmation = self.snapshot(offset: 2, weeklyUsed: 49, weeklyReset: self.resetAt)

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: confirmation)
                == .publishConfirmation)
    }

    @Test
    func `two low observations publish only for an advanced equivalent boundary`() {
        let nextReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let initial = self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: nextReset)
        let confirmation = self.snapshot(
            offset: 2,
            weeklyUsed: 0.5,
            weeklyReset: nextReset.addingTimeInterval(119))

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: confirmation)
                == .publishConfirmation)
    }

    @Test
    func `unchanged regressed and mismatched reset boundaries preserve the previous snapshot`() {
        let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let unchanged = self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: self.resetAt)
        let regressed = self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: self.resetAt.addingTimeInterval(-1))
        let advanced = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let initial = self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: advanced)
        let mismatched = self.snapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: advanced.addingTimeInterval(120))
        let jitteredInitial = self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: self.resetAt.addingTimeInterval(60))
        let jitteredConfirmation = self.snapshot(
            offset: 2,
            weeklyUsed: 0.5,
            weeklyReset: self.resetAt.addingTimeInterval(90))

        for candidate in [unchanged, regressed] {
            #expect(
                CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: candidate)
                    == .requiresConfirmation)
            #expect(
                CodexWeeklyResetConfirmation.confirmationDecision(
                    previous: previous,
                    initial: candidate,
                    confirmation: self.snapshot(offset: 2, weeklyUsed: 50, weeklyReset: self.resetAt))
                    == .publishConfirmation)
            #expect(
                CodexWeeklyResetConfirmation.confirmationDecision(
                    previous: previous,
                    initial: candidate,
                    confirmation: self.snapshot(
                        offset: 2,
                        weeklyUsed: 0,
                        weeklyReset: candidate.secondary?.resetsAt))
                    == .preservePrevious)
        }
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: mismatched)
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: jitteredInitial,
                confirmation: jitteredConfirmation)
                == .preservePrevious)
    }

    @Test
    func `stale confirmations preserve the previous snapshot`() {
        let nextReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let initial = self.snapshot(offset: 2, weeklyUsed: 0, weeklyReset: nextReset)
        let stale = self.snapshot(offset: 2, weeklyUsed: 50, weeklyReset: self.resetAt)

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: stale)
                == .preservePrevious)
    }

    @Test
    func `elapsed and materially regressed boundaries preserve the previous snapshot`() {
        let nextReset = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let high = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let elapsedLow = self.snapshot(
            capturedAt: self.resetAt.addingTimeInterval(1),
            weeklyUsed: 0,
            weeklyReset: self.resetAt)
        let confirmedReset = self.snapshot(offset: 2, weeklyUsed: 0, weeklyReset: nextReset)
        let stalePreReset = self.snapshot(offset: 3, weeklyUsed: 50, weeklyReset: self.resetAt)
        let elapsedConfirmation = self.snapshot(
            capturedAt: nextReset.addingTimeInterval(1),
            weeklyUsed: 0,
            weeklyReset: nextReset)

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: high, initial: elapsedLow)
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: confirmedReset, initial: stalePreReset)
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: high,
                initial: self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: nextReset),
                confirmation: elapsedConfirmation)
                == .preservePrevious)
    }

    @Test
    func `nonfinite percentages timestamps and boundaries fail closed`() {
        let previous = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let initial = self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: self.resetAt.addingTimeInterval(100))
        let nonfiniteBoundary = Date(timeIntervalSinceReferenceDate: .infinity)

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(
                previous: previous,
                initial: self.snapshot(offset: 1, weeklyUsed: .nan, weeklyReset: self.resetAt))
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(
                previous: previous,
                initial: self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: nonfiniteBoundary))
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.initialDecision(
                previous: previous,
                initial: self.snapshot(
                    capturedAt: Date(timeIntervalSinceReferenceDate: .infinity),
                    weeklyUsed: 0,
                    weeklyReset: self.resetAt))
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: self.snapshot(offset: 2, weeklyUsed: .infinity, weeklyReset: self.resetAt))
                == .preservePrevious)
    }

    private func snapshot(
        offset: TimeInterval,
        weeklyUsed: Double?,
        weeklyReset: Date?,
        weeklyInPrimary: Bool = false) -> UsageSnapshot
    {
        self.snapshot(
            capturedAt: self.capturedAt.addingTimeInterval(offset),
            weeklyUsed: weeklyUsed,
            weeklyReset: weeklyReset,
            weeklyInPrimary: weeklyInPrimary)
    }

    private func snapshot(
        capturedAt: Date,
        weeklyUsed: Double?,
        weeklyReset: Date?,
        weeklyInPrimary: Bool = false) -> UsageSnapshot
    {
        let weekly = weeklyUsed.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil)
        }
        let session = RateWindow(
            usedPercent: 25,
            windowMinutes: 300,
            resetsAt: self.resetAt,
            resetDescription: nil)
        return UsageSnapshot(
            primary: weeklyInPrimary ? weekly : session,
            secondary: weeklyInPrimary ? session : weekly,
            updatedAt: capturedAt)
    }
}
