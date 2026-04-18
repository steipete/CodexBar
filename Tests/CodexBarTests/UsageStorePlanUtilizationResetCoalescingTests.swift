import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationResetCoalescingTests {
    @Test
    func `same hour entry backfills missing reset metadata`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let existing = planEntry(
            at: hourStart.addingTimeInterval(10 * 60),
            usedPercent: 20)
        let incoming = planEntry(
            at: hourStart.addingTimeInterval(45 * 60),
            usedPercent: 30,
            resetsAt: hourStart.addingTimeInterval(30 * 60))

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [existing],
                entry: incoming))

        #expect(updated.count == 1)
        #expect(updated[0].capturedAt == incoming.capturedAt)
        #expect(updated[0].usedPercent == 30)
        #expect(updated[0].resetsAt == incoming.resetsAt)
    }

    @Test
    func `same hour later higher usage without reset metadata keeps promoted reset boundary`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let first = planEntry(
            at: hourStart.addingTimeInterval(10 * 60),
            usedPercent: 40)
        let second = planEntry(
            at: hourStart.addingTimeInterval(25 * 60),
            usedPercent: 8,
            resetsAt: hourStart.addingTimeInterval(30 * 60))
        let third = planEntry(
            at: hourStart.addingTimeInterval(50 * 60),
            usedPercent: 22)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [],
                entry: first))
        let promoted = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: initial,
                entry: second))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: promoted,
                entry: third))

        #expect(updated.count == 1)
        #expect(updated[0].capturedAt == third.capturedAt)
        #expect(updated[0].usedPercent == third.usedPercent)
        #expect(updated[0].resetsAt == second.resetsAt)
    }

    @Test
    func `same hour zero usage with drifting reset coalesces to latest entry`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 20,
            hour: 0)))
        let existing = planEntry(
            at: hourStart.addingTimeInterval(14 * 60),
            usedPercent: 0,
            resetsAt: hourStart.addingTimeInterval(5 * 60 * 60 + 14 * 60 + 2))
        let incoming = planEntry(
            at: hourStart.addingTimeInterval(23 * 60),
            usedPercent: 0,
            resetsAt: hourStart.addingTimeInterval(5 * 60 * 60 + 14 * 60 + 3))

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [existing],
                entry: incoming))

        #expect(updated.count == 1)
        #expect(updated[0] == incoming)
    }

    @Test
    func `same hour reset times within two minutes still keep single hourly peak`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 20,
            hour: 0)))
        let existing = planEntry(
            at: hourStart.addingTimeInterval(21 * 60),
            usedPercent: 10,
            resetsAt: hourStart.addingTimeInterval(3 * 60 * 60))
        let incoming = planEntry(
            at: hourStart.addingTimeInterval(55 * 60),
            usedPercent: 10,
            resetsAt: hourStart.addingTimeInterval(3 * 60 * 60 + 1))

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [existing],
                entry: incoming))

        #expect(updated.count == 1)
        #expect(updated[0].capturedAt == incoming.capturedAt)
        #expect(updated[0].usedPercent == 10)
        #expect(updated[0].resetsAt == incoming.resetsAt)
    }

    @Test
    func `same hour usage drop without meaningful reset still keeps single hourly peak`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 20,
            hour: 0)))
        let existing = planEntry(
            at: hourStart.addingTimeInterval(15 * 60),
            usedPercent: 40,
            resetsAt: hourStart.addingTimeInterval(3 * 60 * 60))
        let incoming = planEntry(
            at: hourStart.addingTimeInterval(45 * 60),
            usedPercent: 5,
            resetsAt: hourStart.addingTimeInterval(3 * 60 * 60 + 30))

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [existing],
                entry: incoming))

        #expect(updated.count == 1)
        #expect(updated[0].capturedAt == existing.capturedAt)
        #expect(updated[0].usedPercent == existing.usedPercent)
        #expect(updated[0].resetsAt == incoming.resetsAt)
    }

    @Test
    func `same hour reset keeps peak before reset and latest peak after reset`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 20,
            hour: 0)))
        let initial = [
            planEntry(
                at: hourStart.addingTimeInterval(5 * 60),
                usedPercent: 40,
                resetsAt: hourStart.addingTimeInterval(3 * 60 * 60)),
            planEntry(
                at: hourStart.addingTimeInterval(20 * 60),
                usedPercent: 12,
                resetsAt: hourStart.addingTimeInterval(8 * 60 * 60)),
        ]
        let incoming = planEntry(
            at: hourStart.addingTimeInterval(45 * 60),
            usedPercent: 18,
            resetsAt: hourStart.addingTimeInterval(8 * 60 * 60))

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: initial,
                entry: incoming))

        #expect(updated.count == 2)
        #expect(updated[0].usedPercent == 40)
        #expect(updated[1].usedPercent == 18)
        #expect(updated[1].resetsAt == incoming.resetsAt)
    }

    @Test
    func `newer reset within hour replaces earlier post reset record`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 20,
            hour: 0)))
        let initial = [
            planEntry(
                at: hourStart.addingTimeInterval(5 * 60),
                usedPercent: 40,
                resetsAt: hourStart.addingTimeInterval(3 * 60 * 60)),
            planEntry(
                at: hourStart.addingTimeInterval(20 * 60),
                usedPercent: 12,
                resetsAt: hourStart.addingTimeInterval(8 * 60 * 60)),
        ]
        let incoming = planEntry(
            at: hourStart.addingTimeInterval(50 * 60),
            usedPercent: 3,
            resetsAt: hourStart.addingTimeInterval(10 * 60 * 60))

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: initial,
                entry: incoming))

        #expect(updated.count == 2)
        #expect(updated[0].usedPercent == 40)
        #expect(updated[1] == incoming)
    }

    @Test
    func `merged histories keep series separated by stable name`() throws {
        let existing = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ]),
        ]
        let incoming = [
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 40),
            ]),
        ]

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoriesForTesting(
                existingHistories: existing,
                samples: incoming))

        #expect(findSeries(updated, name: .session, windowMinutes: 300) != nil)
        #expect(findSeries(updated, name: .weekly, windowMinutes: 10080) != nil)
    }
}
