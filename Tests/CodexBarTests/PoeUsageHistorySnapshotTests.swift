import CodexBarCore
import Foundation
import Testing

struct PoeUsageHistorySnapshotTests {
    // MARK: - summary(days:)

    @Test
    func `summary over empty daily returns zeroed summary with nil cost`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: [],
            updatedAt: Date())

        let summary = snapshot.summary(days: 7)

        #expect(summary.points == 0)
        #expect(summary.requests == 0)
        #expect(summary.costUSD == nil)
    }

    @Test
    func `summary over single day reports that day's points and requests`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: [PoeUsageHistorySnapshot.DailyBucket(
                day: "2026-05-31",
                points: 250,
                requests: 3,
                costUSD: 0.05)],
            updatedAt: Date())

        let summary = snapshot.summary(days: 1)

        #expect(summary.points == 250)
        #expect(summary.requests == 3)
        #expect(summary.costUSD == 0.05)
    }

    @Test
    func `summary over seven days uses the last seven daily buckets`() {
        let daily: [PoeUsageHistorySnapshot.DailyBucket] = (1...10).map { offset in
            PoeUsageHistorySnapshot.DailyBucket(
                day: String(format: "2026-05-%02d", offset),
                points: Double(offset * 10),
                requests: offset,
                costUSD: nil)
        }
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: daily,
            updatedAt: Date())

        // Last 7 buckets: offsets 4..10 → 40+50+60+70+80+90+100 = 490
        let summary = snapshot.summary(days: 7)

        #expect(summary.points == 490)
        #expect(summary.requests == 4 + 5 + 6 + 7 + 8 + 9 + 10)
        #expect(summary.costUSD == nil)
    }

    @Test
    func `summary clamps zero and negative day counts up to one`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: [
                PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-29", points: 100, requests: 1, costUSD: nil),
                PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-30", points: 200, requests: 2, costUSD: nil),
                PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-31", points: 300, requests: 3, costUSD: nil),
            ],
            updatedAt: Date())

        #expect(snapshot.summary(days: 0).points == 300) // last bucket only
        #expect(snapshot.summary(days: 0).requests == 3)
        #expect(snapshot.summary(days: -5).points == 300) // clamped up to 1
    }

    @Test
    func `summary ignores daily buckets beyond the requested window`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: (1...30).map { offset in
                PoeUsageHistorySnapshot.DailyBucket(
                    day: String(format: "2026-04-%02d", offset),
                    points: 1,
                    requests: 1,
                    costUSD: nil)
            },
            updatedAt: Date())

        let last30 = snapshot.summary(days: 30)
        let last7 = snapshot.summary(days: 7)

        #expect(last30.points == 30)
        #expect(last7.points == 7)
    }

    @Test
    func `summary reports nil cost when every daily bucket has nil cost`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: (1...3).map { offset in
                PoeUsageHistorySnapshot.DailyBucket(
                    day: "2026-05-\(28 + offset)",
                    points: 50,
                    requests: 1,
                    costUSD: nil)
            },
            updatedAt: Date())

        #expect(snapshot.summary(days: 7).costUSD == nil)
    }

    @Test
    func `summary sums only the non-nil cost buckets and keeps the rest invisible`() throws {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: [
                PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-29", points: 100, requests: 1, costUSD: nil),
                PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-30", points: 200, requests: 1, costUSD: 0.10),
                PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-31", points: 300, requests: 1, costUSD: 0.20),
            ],
            updatedAt: Date())

        // Skips the nil bucket, sums 0.10 + 0.20 (allow IEEE-754 round-trip)
        let cost = try #require(snapshot.summary(days: 7).costUSD)
        #expect(abs(cost - 0.30) < 1e-9)
    }

    // MARK: - latestDay / last7Days / last30Days shortcuts

    @Test
    func `latest day, last 7 and last 30 days agree with summary by day count`() {
        let daily: [PoeUsageHistorySnapshot.DailyBucket] = (1...40).map { offset in
            PoeUsageHistorySnapshot.DailyBucket(
                day: String(format: "2026-04-%02d", offset),
                points: Double(offset),
                requests: 1,
                costUSD: nil)
        }
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: daily,
            updatedAt: Date())

        #expect(snapshot.latestDay == snapshot.summary(days: 1))
        #expect(snapshot.last7Days == snapshot.summary(days: 7))
        #expect(snapshot.last30Days == snapshot.summary(days: 30))
    }

    @Test
    func `current day does not reuse a stale latest bucket`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-23T12:00:00Z"))
        let yesterday = try #require(ISO8601DateFormatter().date(from: "2026-06-22T12:00:00Z"))
        let snapshot = PoeUsageHistorySnapshot(
            entries: [
                self.makeEntry(
                    id: "stale",
                    createdAt: yesterday,
                    model: "GPT-4o",
                    usageType: "chat",
                    points: 100,
                    costUSD: 0.10),
            ],
            daily: [
                PoeUsageHistorySnapshot.DailyBucket(
                    day: "2026-06-22",
                    points: 100,
                    requests: 1,
                    costUSD: 0.10),
            ],
            updatedAt: now)

        #expect(snapshot.latestDay.points == 100)
        #expect(snapshot.currentDay(now: now, calendar: calendar).points == 0)
        #expect(snapshot.currentDay(now: now, calendar: calendar).requests == 0)
        #expect(snapshot.currentDay(now: now, calendar: calendar).costUSD == nil)
    }

    @Test
    func `current day filters raw entries across a UTC bucket boundary`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-23T01:00:00Z"))
        let localToday = try #require(ISO8601DateFormatter().date(from: "2026-06-22T20:00:00Z"))
        let localYesterday = try #require(ISO8601DateFormatter().date(from: "2026-06-22T06:00:00Z"))
        let snapshot = PoeUsageHistorySnapshot(
            entries: [
                self.makeEntry(
                    id: "today",
                    createdAt: localToday,
                    model: "GPT-4o",
                    usageType: "chat",
                    points: 80,
                    costUSD: 0.08),
                self.makeEntry(
                    id: "yesterday",
                    createdAt: localYesterday,
                    model: "Claude",
                    usageType: "chat",
                    points: 20,
                    costUSD: 0.02),
            ],
            daily: [
                PoeUsageHistorySnapshot.DailyBucket(
                    day: "2026-06-22",
                    points: 100,
                    requests: 2,
                    costUSD: 0.10),
            ],
            updatedAt: now)

        let current = snapshot.currentDay(now: now, calendar: calendar)
        #expect(current.points == 80)
        #expect(current.requests == 1)
        #expect(current.costUSD == 0.08)
    }

    // MARK: - topModels / topModel

    @Test
    func `top models is empty when entries is empty`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: [],
            updatedAt: Date())

        #expect(snapshot.topModels.isEmpty)
        #expect(snapshot.topModel == nil)
    }

    @Test
    func `top models groups by model and sums points and requests`() {
        let entries = [
            self.makeEntry(id: "1", model: "GPT-4o", usageType: "chat", points: 10, costUSD: 0.01),
            self.makeEntry(id: "2", model: "GPT-4o", usageType: "chat", points: 5, costUSD: 0.01),
            self.makeEntry(id: "3", model: "Claude-3.7", usageType: "chat", points: 20, costUSD: 0.02),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        let top = snapshot.topModels

        #expect(top.count == 2)
        #expect(top[0].name == "Claude-3.7")
        #expect(top[0].points == 20)
        #expect(top[0].requests == 1)
        #expect(top[1].name == "GPT-4o")
        #expect(top[1].points == 15)
        #expect(top[1].requests == 2)
    }

    @Test
    func `top models breaks ties by name ascending`() {
        let entries = [
            self.makeEntry(id: "1", model: "Z-Model", usageType: "chat", points: 10, costUSD: nil),
            self.makeEntry(id: "2", model: "A-Model", usageType: "chat", points: 10, costUSD: nil),
            self.makeEntry(id: "3", model: "M-Model", usageType: "chat", points: 10, costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        let top = snapshot.topModels
        #expect(top.map(\.name) == ["A-Model", "M-Model", "Z-Model"])
    }

    @Test
    func `top models falls back to unknown for empty or whitespace model strings`() {
        let entries = [
            self.makeEntry(id: "1", model: "GPT-4o", usageType: "chat", points: 5, costUSD: nil),
            self.makeEntry(id: "2", model: "", usageType: "chat", points: 5, costUSD: nil),
            self.makeEntry(id: "3", model: "   ", usageType: "chat", points: 5, costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        let top = snapshot.topModels
        let names = top.map(\.name)
        #expect(names.contains("unknown"))
        #expect(names.contains("GPT-4o"))
    }

    @Test
    func `top models omits cost when no entry reported cost`() {
        let entries = [
            self.makeEntry(id: "1", model: "GPT-4o", usageType: "chat", points: 5, costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        #expect(snapshot.topModels.first?.costUSD == nil)
    }

    @Test
    func `top models sums cost across entries for the same model`() {
        let entries = [
            self.makeEntry(id: "1", model: "GPT-4o", usageType: "chat", points: 5, costUSD: 0.01),
            self.makeEntry(id: "2", model: "GPT-4o", usageType: "chat", points: 5, costUSD: 0.02),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        #expect(snapshot.topModels.first?.costUSD == 0.03)
    }

    // MARK: - topUsageTypes / topUsageType

    @Test
    func `top usage types groups by usage type independent of model`() {
        let entries = [
            self.makeEntry(id: "1", model: "GPT-4o", usageType: "chat", points: 5, costUSD: nil),
            self.makeEntry(id: "2", model: "Claude", usageType: "chat", points: 10, costUSD: nil),
            self.makeEntry(id: "3", model: "GPT-4o", usageType: "api", points: 8, costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        let top = snapshot.topUsageTypes
        #expect(top.map(\.name) == ["chat", "api"])
        #expect(top[0].points == 15)
        #expect(top[0].requests == 2)
    }

    @Test
    func `top usage type is the first entry in top usage types`() {
        let entries = [
            self.makeEntry(id: "1", model: "GPT-4o", usageType: "chat", points: 5, costUSD: nil),
            self.makeEntry(id: "2", model: "GPT-4o", usageType: "api", points: 10, costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: Date())

        #expect(snapshot.topUsageType == "api")
        #expect(snapshot.topUsageType == snapshot.topUsageTypes.first?.name)
    }

    @Test
    func `top usage type is nil for empty entries`() {
        let snapshot = PoeUsageHistorySnapshot(
            entries: [],
            daily: [],
            updatedAt: Date())

        #expect(snapshot.topUsageType == nil)
    }

    // MARK: - recentEntries(limit:)

    @Test
    func `recent entries returns up to the requested limit, newest first`() {
        let now = Date(timeIntervalSince1970: 1_717_000_000)
        let entries = (0..<5).map { offset in
            self.makeEntry(
                id: "\(offset)",
                createdAt: now.addingTimeInterval(TimeInterval(offset * 60)),
                model: "GPT-4o",
                usageType: "chat",
                points: 1,
                costUSD: nil)
        }
        // entries are passed in order they came back; init should sort
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: now)

        let recent = snapshot.recentEntries(limit: 3)

        #expect(recent.count == 3)
        // Newest three (offsets 4, 3, 2) should be first
        #expect(recent[0].id == "4")
        #expect(recent[1].id == "3")
        #expect(recent[2].id == "2")
    }

    @Test
    func `recent entries clamps non-positive limit up to one`() {
        let now = Date(timeIntervalSince1970: 1_717_000_000)
        let entries = (0..<3).map { offset in
            self.makeEntry(
                id: "\(offset)",
                createdAt: now.addingTimeInterval(TimeInterval(offset * 60)),
                model: "GPT-4o",
                usageType: "chat",
                points: 1,
                costUSD: nil)
        }
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: now)

        #expect(snapshot.recentEntries(limit: 0).count == 1)
        #expect(snapshot.recentEntries(limit: -3).count == 1)
        #expect(snapshot.recentEntries(limit: 0).first?.id == "2")
    }

    @Test
    func `recent entries returns everything when limit exceeds entries count`() {
        let now = Date(timeIntervalSince1970: 1_717_000_000)
        let entries = [
            self.makeEntry(id: "1", createdAt: now, model: "A", usageType: "t", points: 1, costUSD: nil),
            self.makeEntry(
                id: "2",
                createdAt: now.addingTimeInterval(60),
                model: "A",
                usageType: "t",
                points: 1,
                costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: [],
            updatedAt: now)

        let recent = snapshot.recentEntries(limit: 10)
        #expect(recent.count == 2)
    }

    // MARK: - Init sorting invariants

    @Test
    func `init sorts entries ascending by created at and daily ascending by day string`() {
        let now = Date(timeIntervalSince1970: 1_717_000_000)
        let entries = [
            self.makeEntry(
                id: "newer",
                createdAt: now.addingTimeInterval(120),
                model: "A",
                usageType: "t",
                points: 1,
                costUSD: nil),
            self.makeEntry(id: "older", createdAt: now, model: "A", usageType: "t", points: 1, costUSD: nil),
        ]
        let daily = [
            PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-31", points: 1, requests: 1, costUSD: nil),
            PoeUsageHistorySnapshot.DailyBucket(day: "2026-05-30", points: 1, requests: 1, costUSD: nil),
        ]
        let snapshot = PoeUsageHistorySnapshot(
            entries: entries,
            daily: daily,
            updatedAt: now)

        // Public init sorts entries ASC by createdAt, daily ASC by day
        // (consumers wanting newest-first should use recentEntries(limit:))
        #expect(snapshot.entries.first?.id == "older")
        #expect(snapshot.entries.last?.id == "newer")
        #expect(snapshot.daily.first?.day == "2026-05-30")
        #expect(snapshot.daily.last?.day == "2026-05-31")
    }

    // MARK: - Helpers

    private func makeEntry(
        id: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_717_000_000),
        model: String,
        usageType: String,
        points: Double,
        costUSD: Double?) -> PoeUsageHistorySnapshot.Entry
    {
        PoeUsageHistorySnapshot.Entry(
            id: id,
            createdAt: createdAt,
            model: model,
            usageType: usageType,
            points: points,
            costUSD: costUSD)
    }
}
