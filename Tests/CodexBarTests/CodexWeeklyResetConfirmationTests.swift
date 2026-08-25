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
            capturedAt: self.resetAt.addingTimeInterval(-60),
            weeklyUsed: 50,
            weeklyReset: self.resetAt,
            weeklyInPrimary: true)
        let initial = self.snapshot(
            capturedAt: self.resetAt.addingTimeInterval(1),
            weeklyUsed: 0,
            weeklyReset: nextReset,
            weeklyInPrimary: true)
        let confirmation = self.snapshot(
            capturedAt: self.resetAt.addingTimeInterval(2),
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
        let previous = self.snapshot(
            capturedAt: self.resetAt.addingTimeInterval(-60),
            weeklyUsed: 50,
            weeklyReset: self.resetAt)
        let initial = self.snapshot(
            capturedAt: self.resetAt.addingTimeInterval(1),
            weeklyUsed: 0,
            weeklyReset: nextReset)
        let confirmation = self.snapshot(
            capturedAt: self.resetAt.addingTimeInterval(2),
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
    func `matching rolling boundary before prior reset preserves the previous snapshot`() throws {
        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-07-28T03:09:20Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-02T10:17:56Z"))
        let initialCapturedAt = try #require(formatter.date(from: "2026-07-28T03:59:23Z"))
        let initialReset = try #require(formatter.date(from: "2026-08-04T03:59:21Z"))
        let previous = self.snapshot(
            capturedAt: previousCapturedAt,
            weeklyUsed: 100,
            weeklyReset: previousReset)
        let initial = self.snapshot(
            capturedAt: initialCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset)
        let confirmation = self.snapshot(
            capturedAt: initialCapturedAt.addingTimeInterval(30),
            weeklyUsed: 0,
            weeklyReset: initialReset.addingTimeInterval(30))

        #expect(
            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: initial)
                == .requiresConfirmation)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: confirmation)
                == .preservePrevious)
    }

    @Test
    func `redeemed reset credit confirms an early manual weekly reset`() throws {
        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-07-28T03:09:20Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-02T10:17:56Z"))
        let initialCapturedAt = try #require(formatter.date(from: "2026-07-28T03:59:23Z"))
        let initialReset = try #require(formatter.date(from: "2026-08-04T03:59:21Z"))
        let previous = self.snapshot(
            capturedAt: previousCapturedAt,
            weeklyUsed: 100,
            weeklyReset: previousReset,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: previousCapturedAt))
        let initial = self.snapshot(
            capturedAt: initialCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset,
            resetCredits: self.resetCredits(
                status: .redeeming,
                capturedAt: initialCapturedAt))
        let confirmationCapturedAt = initialCapturedAt.addingTimeInterval(30)
        let confirmation = self.snapshot(
            capturedAt: confirmationCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset.addingTimeInterval(30),
            resetCredits: self.resetCredits(
                status: .redeemed,
                capturedAt: confirmationCapturedAt))

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
    func `consumed reset credit omitted by provider confirms an early manual weekly reset`() throws {
        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-08-06T09:28:18Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-10T01:00:26Z"))
        let initialCapturedAt = try #require(formatter.date(from: "2026-08-06T09:33:18Z"))
        let initialReset = try #require(formatter.date(from: "2026-08-13T09:33:18Z"))
        let previous = self.snapshot(
            capturedAt: previousCapturedAt,
            weeklyUsed: 99,
            weeklyReset: previousReset,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: previousCapturedAt))
        let initial = self.snapshot(
            capturedAt: initialCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset,
            resetCredits: self.emptyResetCredits(capturedAt: initialCapturedAt))
        let confirmationCapturedAt = initialCapturedAt.addingTimeInterval(30)
        let confirmation = self.snapshot(
            capturedAt: confirmationCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset.addingTimeInterval(30),
            resetCredits: self.emptyResetCredits(capturedAt: confirmationCapturedAt))

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
    func `zero available reset credits confirm a server-side early weekly reset by observation`() throws {
        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-08-13T03:36:16Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-18T00:49:16Z"))
        let initialCapturedAt = try #require(formatter.date(from: "2026-08-13T03:41:46Z"))
        let initialReset = try #require(formatter.date(from: "2026-08-20T03:38:06Z"))
        let previous = self.snapshot(
            capturedAt: previousCapturedAt,
            weeklyUsed: 98,
            weeklyReset: previousReset,
            resetCredits: self.emptyResetCredits(capturedAt: previousCapturedAt))
        let initial = self.snapshot(
            capturedAt: initialCapturedAt,
            weeklyUsed: 1,
            weeklyReset: initialReset,
            resetCredits: self.emptyResetCredits(capturedAt: initialCapturedAt))
        let confirmation = self.snapshot(
            capturedAt: initialCapturedAt.addingTimeInterval(30),
            weeklyUsed: 1,
            weeklyReset: initialReset.addingTimeInterval(30),
            resetCredits: self.emptyResetCredits(capturedAt: initialCapturedAt.addingTimeInterval(30)))

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
    func `one missing reset credit inventory does not confirm an early manual weekly reset`() throws {
        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-08-06T09:28:18Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-10T01:00:26Z"))
        let initialCapturedAt = try #require(formatter.date(from: "2026-08-06T09:33:18Z"))
        let initialReset = try #require(formatter.date(from: "2026-08-13T09:33:18Z"))
        let previousCredits = self.resetCredits(
            status: .available,
            capturedAt: previousCapturedAt)
        let previous = self.snapshot(
            capturedAt: previousCapturedAt,
            weeklyUsed: 99,
            weeklyReset: previousReset,
            resetCredits: previousCredits)
        let initial = self.snapshot(
            capturedAt: initialCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset,
            resetCredits: previousCredits)
        let confirmationCapturedAt = initialCapturedAt.addingTimeInterval(30)
        let confirmation = self.snapshot(
            capturedAt: confirmationCapturedAt,
            weeklyUsed: 0,
            weeklyReset: initialReset.addingTimeInterval(30),
            resetCredits: self.emptyResetCredits(capturedAt: confirmationCapturedAt))

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: confirmation)
                == .preservePrevious)
    }

    @Test
    func `expired omitted reset credit does not confirm an early manual weekly reset`() throws {
        let formatter = ISO8601DateFormatter()
        let previousCapturedAt = try #require(formatter.date(from: "2026-08-06T09:28:18Z"))
        let previousReset = try #require(formatter.date(from: "2026-08-10T01:00:26Z"))
        let initialCapturedAt = try #require(formatter.date(from: "2026-08-06T09:33:18Z"))
        let initialReset = try #require(formatter.date(from: "2026-08-13T09:33:18Z"))
        let confirmationCapturedAt = initialCapturedAt.addingTimeInterval(30)

        for expiresAt in [
            initialCapturedAt.addingTimeInterval(-1),
            initialCapturedAt.addingTimeInterval(15),
        ] {
            let previous = self.snapshot(
                capturedAt: previousCapturedAt,
                weeklyUsed: 99,
                weeklyReset: previousReset,
                resetCredits: self.resetCredits(
                    status: .available,
                    capturedAt: previousCapturedAt,
                    expiresAt: expiresAt))
            let initial = self.snapshot(
                capturedAt: initialCapturedAt,
                weeklyUsed: 0,
                weeklyReset: initialReset,
                resetCredits: self.emptyResetCredits(capturedAt: initialCapturedAt))
            let confirmation = self.snapshot(
                capturedAt: confirmationCapturedAt,
                weeklyUsed: 0,
                weeklyReset: initialReset.addingTimeInterval(30),
                resetCredits: self.emptyResetCredits(capturedAt: confirmationCapturedAt))

            #expect(
                CodexWeeklyResetConfirmation.confirmationDecision(
                    previous: previous,
                    initial: initial,
                    confirmation: confirmation)
                    == .preservePrevious)
        }
    }

    @Test
    func `prior boundary due tolerance includes the exact two minute edge`() {
        let previousBoundary = self.resetAt
        let nextBoundary = previousBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = self.snapshot(
            capturedAt: previousBoundary.addingTimeInterval(-10 * 60),
            weeklyUsed: 100,
            weeklyReset: previousBoundary)
        let initial = self.snapshot(
            capturedAt: previousBoundary.addingTimeInterval(-121),
            weeklyUsed: 0,
            weeklyReset: nextBoundary)
        let atToleranceEdge = self.snapshot(
            capturedAt: previousBoundary.addingTimeInterval(-120),
            weeklyUsed: 0,
            weeklyReset: nextBoundary)
        let justBeforeToleranceEdge = self.snapshot(
            capturedAt: previousBoundary.addingTimeInterval(-120.001),
            weeklyUsed: 0,
            weeklyReset: nextBoundary)

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: atToleranceEdge)
                == .publishConfirmation)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: justBeforeToleranceEdge)
                == .preservePrevious)
    }

    @Test
    func `immediate confirmation does not admit a premature confirmed low`() {
        let previous = self.identified(
            self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt))
        let unchanged = self.identified(
            self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: self.resetAt))
        let regressed = self.identified(self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: self.resetAt.addingTimeInterval(-1)))
        let advanced = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let initial = self.identified(
            self.snapshot(offset: 1, weeklyUsed: 0, weeklyReset: advanced))
        let mismatched = self.identified(self.snapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: advanced.addingTimeInterval(120)))
        let jitteredInitial = self.identified(self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: self.resetAt.addingTimeInterval(60)))
        let jitteredConfirmation = self.identified(self.snapshot(
            offset: 2,
            weeklyUsed: 0.5,
            weeklyReset: self.resetAt.addingTimeInterval(90)))

        for candidate in [unchanged, regressed] {
            #expect(
                CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: candidate)
                    == .requiresConfirmation)
            #expect(
                CodexWeeklyResetConfirmation.confirmationDecision(
                    previous: previous,
                    initial: candidate,
                    confirmation: self.identified(
                        self.snapshot(offset: 2, weeklyUsed: 50, weeklyReset: self.resetAt)))
                    == .publishConfirmation)
        }

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: unchanged,
                confirmation: self.identified(
                    self.snapshot(offset: 2, weeklyUsed: 0, weeklyReset: self.resetAt)))
                == .preservePrevious)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: regressed,
                confirmation: self.identified(
                    self.snapshot(offset: 2, weeklyUsed: 0, weeklyReset: regressed.secondary?.resetsAt)))
                == .preservePrevious)
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
    func `unchanged boundary confirmation remains private within one refresh`() {
        let previous = self.identified(
            self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt),
            email: "stable@example.com",
            plan: "pro")
        let initial = self.identified(
            self.snapshot(offset: 1, weeklyUsed: 0.5, weeklyReset: self.resetAt),
            email: "stable@example.com",
            plan: "pro")
        let confirmation = self.identified(
            self.snapshot(offset: 2, weeklyUsed: 0.8, weeklyReset: self.resetAt),
            email: "stable@example.com",
            plan: "pro")

        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: previous,
                initial: initial,
                confirmation: confirmation) == .preservePrevious)
        for incompatible in [
            self.identified(confirmation, email: "other@example.com", plan: "pro"),
            self.identified(confirmation, email: "stable@example.com", plan: "plus"),
            self.identified(confirmation, email: nil, plan: "pro"),
            self.identified(confirmation, email: "stable@example.com", plan: nil),
        ] {
            #expect(
                CodexWeeklyResetConfirmation.confirmationDecision(
                    previous: previous,
                    initial: initial,
                    confirmation: incompatible) == .preservePrevious)
        }

        let unidentifiedPrevious = self.snapshot(offset: 0, weeklyUsed: 50, weeklyReset: self.resetAt)
        let unidentifiedInitial = self.snapshot(offset: 1, weeklyUsed: 0.5, weeklyReset: self.resetAt)
        let unidentifiedConfirmation = self.snapshot(offset: 2, weeklyUsed: 0.8, weeklyReset: self.resetAt)
        #expect(
            CodexWeeklyResetConfirmation.confirmationDecision(
                previous: unidentifiedPrevious,
                initial: unidentifiedInitial,
                confirmation: unidentifiedConfirmation) == .preservePrevious)
    }

    @Test
    func `consumed reset credit remains strong evidence with an unchanged boundary`() {
        let expiry = self.resetAt.addingTimeInterval(24 * 60 * 60)
        let previous = self.identified(self.snapshot(
            offset: 0,
            weeklyUsed: 50,
            weeklyReset: self.resetAt,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt,
                expiresAt: expiry)))
        let initial = self.identified(self.snapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: self.resetAt,
            resetCredits: self.resetCredits(
                status: .redeemed,
                capturedAt: self.capturedAt.addingTimeInterval(1),
                expiresAt: expiry)))
        let confirmation = self.identified(self.snapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: self.resetAt,
            resetCredits: self.resetCredits(
                status: .redeemed,
                capturedAt: self.capturedAt.addingTimeInterval(2),
                expiresAt: expiry)))

        #expect(CodexWeeklyResetConfirmation.confirmationDecision(
            previous: previous,
            initial: initial,
            confirmation: confirmation) == .publishConfirmation)
    }
}

extension CodexWeeklyResetConfirmationTests {
    @Test
    func `stable positive credit inventory admits an advanced reset only on a later refresh`() throws {
        let nextBoundary = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let expiry = nextBoundary.addingTimeInterval(24 * 60 * 60)
        let previous = self.exactIdentifiedSnapshot(
            offset: 0,
            weeklyUsed: 80,
            weeklyReset: self.resetAt,
            resetCredits: self.resetCredits(status: .available, capturedAt: self.capturedAt, expiresAt: expiry))
        let initial = self.exactIdentifiedSnapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(1),
                expiresAt: expiry))
        let confirmation = self.exactIdentifiedSnapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(2),
                expiresAt: expiry))
        let candidate = try #require(CodexWeeklyResetConfirmation.makeDelayedCandidate(
            previous: previous,
            initial: initial,
            confirmation: confirmation,
            sourceEvidence: .allExactOAuth))

        let tooSoon = self.exactIdentifiedSnapshot(
            offset: 30,
            weeklyUsed: 0.5,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(30),
                expiresAt: expiry))
        let laterRefresh = self.exactIdentifiedSnapshot(
            offset: 61,
            weeklyUsed: 0.7,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(61),
                expiresAt: expiry))
        let expiredRefresh = self.exactIdentifiedSnapshot(
            offset: 1802,
            weeklyUsed: 0.7,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(1802),
                expiresAt: expiry))

        #expect(
            CodexWeeklyResetConfirmation.delayedCandidateDecision(
                previous: previous,
                candidate: candidate,
                current: tooSoon,
                currentIsExactOAuth: true) == .retainCandidate)
        #expect(
            CodexWeeklyResetConfirmation.delayedCandidateDecision(
                previous: previous,
                candidate: candidate,
                current: laterRefresh,
                currentIsExactOAuth: true) == .publishCurrent)
        #expect(
            CodexWeeklyResetConfirmation.delayedCandidateDecision(
                previous: previous,
                candidate: candidate,
                current: expiredRefresh,
                currentIsExactOAuth: true) == .discardCandidate)
    }

    @Test
    func `stable credit inventory ignores provider row ordering`() {
        let nextBoundary = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let expiry = nextBoundary.addingTimeInterval(24 * 60 * 60)
        let previous = self.exactIdentifiedSnapshot(
            offset: 0,
            weeklyUsed: 80,
            weeklyReset: self.resetAt,
            resetCredits: self.availableResetCredits(
                ids: ["credit-a", "credit-b"],
                capturedAt: self.capturedAt,
                expiresAt: expiry))
        let initial = self.exactIdentifiedSnapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.availableResetCredits(
                ids: ["credit-b", "credit-a"],
                capturedAt: self.capturedAt.addingTimeInterval(1),
                expiresAt: expiry))
        let confirmation = self.exactIdentifiedSnapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.availableResetCredits(
                ids: ["credit-a", "credit-b"],
                capturedAt: self.capturedAt.addingTimeInterval(2),
                expiresAt: expiry))

        #expect(CodexWeeklyResetConfirmation.makeDelayedCandidate(
            previous: previous,
            initial: initial,
            confirmation: confirmation,
            sourceEvidence: .allExactOAuth) != nil)
    }

    @Test
    func `delayed candidate fails closed when credit identity changes`() {
        let nextBoundary = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let expiry = nextBoundary.addingTimeInterval(24 * 60 * 60)
        let previous = self.exactIdentifiedSnapshot(
            offset: 0,
            weeklyUsed: 80,
            weeklyReset: self.resetAt,
            resetCredits: self.resetCredits(
                id: "credit-a",
                status: .available,
                capturedAt: self.capturedAt,
                expiresAt: expiry))
        let initial = self.exactIdentifiedSnapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                id: "credit-b",
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(1),
                expiresAt: expiry))
        let confirmation = self.exactIdentifiedSnapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                id: "credit-b",
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(2),
                expiresAt: expiry))

        #expect(CodexWeeklyResetConfirmation.makeDelayedCandidate(
            previous: previous,
            initial: initial,
            confirmation: confirmation,
            sourceEvidence: .allExactOAuth) == nil)
    }

    @Test
    func `delayed candidate rejects zero to positive credits and inconsistent boundaries`() {
        let nextBoundary = self.resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let expiry = nextBoundary.addingTimeInterval(24 * 60 * 60)
        let previous = self.exactIdentifiedSnapshot(
            offset: 0,
            weeklyUsed: 80,
            weeklyReset: self.resetAt,
            resetCredits: self.emptyResetCredits(capturedAt: self.capturedAt))
        let initial = self.exactIdentifiedSnapshot(
            offset: 1,
            weeklyUsed: 0,
            weeklyReset: nextBoundary,
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(1),
                expiresAt: expiry))
        let confirmation = self.exactIdentifiedSnapshot(
            offset: 2,
            weeklyUsed: 0,
            weeklyReset: nextBoundary.addingTimeInterval(120),
            resetCredits: self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt.addingTimeInterval(2),
                expiresAt: expiry))

        #expect(CodexWeeklyResetConfirmation.makeDelayedCandidate(
            previous: previous,
            initial: initial,
            confirmation: self.exactIdentifiedSnapshot(
                offset: 2,
                weeklyUsed: 0,
                weeklyReset: nextBoundary,
                resetCredits: self.resetCredits(
                    status: .available,
                    capturedAt: self.capturedAt.addingTimeInterval(2),
                    expiresAt: expiry)),
            sourceEvidence: .allExactOAuth) == nil)
        #expect(CodexWeeklyResetConfirmation.makeDelayedCandidate(
            previous: previous.withCodexResetCredits(self.resetCredits(
                status: .available,
                capturedAt: self.capturedAt,
                expiresAt: expiry)),
            initial: initial,
            confirmation: confirmation,
            sourceEvidence: .allExactOAuth) == nil)
    }
}

extension CodexWeeklyResetConfirmationTests {
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
        weeklyInPrimary: Bool = false,
        resetCredits: CodexRateLimitResetCreditsSnapshot? = nil) -> UsageSnapshot
    {
        self.snapshot(
            capturedAt: self.capturedAt.addingTimeInterval(offset),
            weeklyUsed: weeklyUsed,
            weeklyReset: weeklyReset,
            weeklyInPrimary: weeklyInPrimary,
            resetCredits: resetCredits)
    }

    private func snapshot(
        capturedAt: Date,
        weeklyUsed: Double?,
        weeklyReset: Date?,
        weeklyInPrimary: Bool = false,
        resetCredits: CodexRateLimitResetCreditsSnapshot? = nil) -> UsageSnapshot
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
            codexResetCredits: resetCredits,
            updatedAt: capturedAt)
    }

    private func identified(
        _ snapshot: UsageSnapshot,
        email: String? = "stable@example.com",
        plan: String? = "pro") -> UsageSnapshot
    {
        snapshot.withIdentity(ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: plan))
    }

    private func exactIdentifiedSnapshot(
        offset: TimeInterval,
        weeklyUsed: Double,
        weeklyReset: Date,
        resetCredits: CodexRateLimitResetCreditsSnapshot) -> UsageSnapshot
    {
        self.identified(self.snapshot(
            offset: offset,
            weeklyUsed: weeklyUsed,
            weeklyReset: weeklyReset,
            resetCredits: resetCredits)).withDataConfidence(.exact)
    }

    private func resetCredits(
        id: String = "manual-reset-credit",
        status: CodexRateLimitResetCreditStatus,
        capturedAt: Date,
        expiresAt: Date? = nil) -> CodexRateLimitResetCreditsSnapshot
    {
        CodexRateLimitResetCreditsSnapshot(
            credits: [CodexRateLimitResetCredit(
                id: id,
                resetType: "codex_rate_limits",
                status: status,
                grantedAt: capturedAt.addingTimeInterval(-24 * 60 * 60),
                expiresAt: expiresAt ?? capturedAt.addingTimeInterval(24 * 60 * 60),
                redeemStartedAt: status == .available ? nil : capturedAt,
                redeemedAt: status == .redeemed ? capturedAt : nil,
                title: nil,
                description: nil)],
            availableCount: status == .available ? 1 : 0,
            updatedAt: capturedAt)
    }

    private func emptyResetCredits(capturedAt: Date) -> CodexRateLimitResetCreditsSnapshot {
        CodexRateLimitResetCreditsSnapshot(
            credits: [],
            availableCount: 0,
            updatedAt: capturedAt)
    }

    private func availableResetCredits(
        ids: [String],
        capturedAt: Date,
        expiresAt: Date) -> CodexRateLimitResetCreditsSnapshot
    {
        CodexRateLimitResetCreditsSnapshot(
            credits: ids.map { id in
                CodexRateLimitResetCredit(
                    id: id,
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: capturedAt.addingTimeInterval(-24 * 60 * 60),
                    expiresAt: expiresAt,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil)
            },
            availableCount: ids.count,
            updatedAt: capturedAt)
    }
}
