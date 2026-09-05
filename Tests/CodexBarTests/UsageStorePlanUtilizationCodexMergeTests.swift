import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationCodexMergeTests {
    @MainActor
    @Test
    func `codex materialize leaves canonical-only history untouched`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .codex, email: "alice@example.com")
        let canonicalKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: snapshot))
        let hourStart = Date(timeIntervalSince1970: 1_699_999_200)
        let session = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: hourStart.addingTimeInterval(3600), usedPercent: 40),
            planEntry(at: hourStart, usedPercent: 10),
        ])
        let weekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: hourStart.addingTimeInterval(7200), usedPercent: 15),
        ])
        // Direct assignment keeps this unsorted; a self-merge would reorder by windowMinutes.
        let originalHistories = [weekly, session]
        let originalBuckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: canonicalKey,
            unscoped: [],
            accounts: [
                canonicalKey: originalHistories,
            ])
        store.planUtilizationHistory[.codex] = originalBuckets
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let revisionBefore = store.planUtilizationHistoryRevision
        let history = store.planUtilizationHistory(for: .codex)
        let buckets = try #require(store.planUtilizationHistory[.codex])

        #expect(history == originalHistories)
        #expect(buckets == originalBuckets)
        #expect(buckets.accounts[canonicalKey] == originalHistories)
        #expect(buckets.accounts.keys.sorted() == [canonicalKey])
        #expect(buckets.unscoped.isEmpty)
        #expect(store.planUtilizationHistoryRevision == revisionBefore)
    }

    @MainActor
    @Test
    func `codex materialize merge matches reference for overlapping hours out of order entries and distinct series`()
        throws
    {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .codex, email: "alice@example.com")
        let canonicalKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: snapshot))
        let legacyEmailHash = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "alice@example.com")
        let hourStart = Date(timeIntervalSince1970: 1_699_999_200)

        let canonicalSession = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: hourStart.addingTimeInterval(3 * 3600), usedPercent: 40),
            planEntry(at: hourStart.addingTimeInterval(5 * 60), usedPercent: 10),
        ])
        let canonicalWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: hourStart, usedPercent: 15),
        ])
        let legacySession = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: hourStart.addingTimeInterval(3600), usedPercent: 20),
            planEntry(at: hourStart.addingTimeInterval(25 * 60), usedPercent: 35),
        ])
        let legacyWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: hourStart.addingTimeInterval(3600), usedPercent: 25),
        ])
        let unscopedSession = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: hourStart.addingTimeInterval(2 * 3600), usedPercent: 30),
        ])

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [unscopedSession],
            accounts: [
                canonicalKey: [canonicalWeekly, canonicalSession],
                legacyEmailHash: [legacySession, legacyWeekly],
            ])
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let history = store.planUtilizationHistory(for: .codex)
        let buckets = try #require(store.planUtilizationHistory[.codex])

        let expectedSession = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: hourStart.addingTimeInterval(25 * 60), usedPercent: 35),
            planEntry(at: hourStart.addingTimeInterval(3600), usedPercent: 20),
            planEntry(at: hourStart.addingTimeInterval(2 * 3600), usedPercent: 30),
            planEntry(at: hourStart.addingTimeInterval(3 * 3600), usedPercent: 40),
        ])
        let expectedWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: hourStart, usedPercent: 15),
            planEntry(at: hourStart.addingTimeInterval(3600), usedPercent: 25),
        ])
        let expectedHistories = [expectedSession, expectedWeekly]

        #expect(history == expectedHistories)
        #expect(buckets.accounts[canonicalKey] == expectedHistories)
        #expect(buckets.accounts[legacyEmailHash] == nil)
        #expect(buckets.unscoped.isEmpty)
        #expect(findSeries(history, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [
            35, 20, 30, 40,
        ])
        #expect(findSeries(history, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [15, 25])
    }

    @MainActor
    @Test
    func `codex materialize merge matches reference when retention trimming is exercised`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let snapshot = UsageStorePlanUtilizationTests.makeSnapshot(provider: .codex, email: "alice@example.com")
        let canonicalKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: snapshot))
        let legacyEmailHash = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "alice@example.com")
        let hourStart = Date(timeIntervalSince1970: 1_699_999_200)
        let maxSamples = UsageStore._planUtilizationMaxSamplesForTesting
        let overflow = 12
        let totalSessionEntries = maxSamples + overflow
        let legacySessionEntries = (0..<totalSessionEntries).map { offset in
            planEntry(
                at: hourStart.addingTimeInterval(Double(offset) * 3600),
                usedPercent: Double(offset % 100))
        }
        let weeklyEntries = [
            planEntry(at: hourStart, usedPercent: 8),
            planEntry(at: hourStart.addingTimeInterval(3600), usedPercent: 11),
        ]

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            canonicalKey: [
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            legacyEmailHash: [
                planSeries(name: .session, windowMinutes: 300, entries: legacySessionEntries),
            ],
        ])
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let history = store.planUtilizationHistory(for: .codex)
        let buckets = try #require(store.planUtilizationHistory[.codex])
        let expectedSessionEntries = Array(legacySessionEntries.dropFirst(overflow))
        let expectedHistories = [
            planSeries(name: .session, windowMinutes: 300, entries: expectedSessionEntries),
            planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
        ]

        #expect(history == expectedHistories)
        #expect(buckets.accounts[canonicalKey] == expectedHistories)
        #expect(buckets.accounts[legacyEmailHash] == nil)
        #expect(findSeries(history, name: .session, windowMinutes: 300)?.entries.count == maxSamples)
        #expect(findSeries(history, name: .session, windowMinutes: 300)?.entries.first?.capturedAt
            == expectedSessionEntries.first?.capturedAt)
        #expect(findSeries(history, name: .session, windowMinutes: 300)?.entries.last
            == expectedSessionEntries.last)
        #expect(findSeries(history, name: .weekly, windowMinutes: 10080)?.entries == weeklyEntries)
    }

    @Test
    func `upper bound is one past the last equal capturedAt`() {
        let probe = Date(timeIntervalSince1970: 1_700_000_000)
        let prefix = (0..<32).map { offset in
            planEntry(at: probe.addingTimeInterval(Double(offset) - 32), usedPercent: Double(offset))
        }
        let equalRun = (0..<16).map { offset in
            planEntry(at: probe, usedPercent: Double(offset))
        }
        let suffix = (1..<18).map { offset in
            planEntry(at: probe.addingTimeInterval(Double(offset)), usedPercent: Double(offset))
        }
        let entries = prefix + equalRun + suffix

        #expect(entries.count == 65)
        #expect(UsageStore._planUtilizationEntryUpperBoundForTesting(entries: entries, capturedAt: probe) == 48)
        #expect(UsageStore._planUtilizationEntryUpperBoundForTesting(
            entries: entries,
            capturedAt: probe.addingTimeInterval(17)) == 65)
        #expect(UsageStore._planUtilizationEntryUpperBoundForTesting(entries: equalRun, capturedAt: probe) == 16)
        #expect(UsageStore._planUtilizationEntryUpperBoundForTesting(
            entries: entries,
            capturedAt: probe.addingTimeInterval(-33)) == 0)
    }

    @Test
    func `decoded series sorts out-of-order entries and round-trips unchanged`() throws {
        let hourStart = Date(timeIntervalSince1970: 1_699_999_200)
        let later = hourStart.addingTimeInterval(3600)
        let earliest = hourStart.addingTimeInterval(-3600)
        let ordered = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: earliest, usedPercent: 10, resetsAt: hourStart),
            planEntry(at: hourStart, usedPercent: 20),
            planEntry(at: later, usedPercent: 30, resetsAt: later.addingTimeInterval(3600)),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(ordered)
        let roundTrip = try decoder.decode(PlanUtilizationSeriesHistory.self, from: encoded)
        #expect(roundTrip == ordered)

        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let entries = try #require(json["entries"] as? [[String: Any]])
        json["entries"] = Array(entries.reversed())
        let decodedShuffled = try decoder.decode(
            PlanUtilizationSeriesHistory.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decodedShuffled == ordered)
        #expect(decodedShuffled.entries.map(\.capturedAt) == [earliest, hourStart, later])
    }
}
