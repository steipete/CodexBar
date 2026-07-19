import Foundation
import Testing
@testable import CodexBarCore

struct ZoomMateCreditsHistoryFetcherTests {
    // Every payload below is generated from synthetic IDs, titles, costs, and timestamps.
    private static let now = Date(timeIntervalSince1970: 1_782_800_000)
    private static let startTime = Self.now.addingTimeInterval(-30 * 24 * 3600)

    private static func page(records: String, total: Int) -> String {
        """
        { "data": { "records": [\(records)], "total": \(total) }, "status_code": 200, "error_message": null }
        """
    }

    private static func record(
        id: String,
        title: String,
        cost: Double,
        time: String,
        isRunning: Bool = false,
        isDeleted: Bool = false) -> String
    {
        """
        {"session_id": "\(id)", "title": "\(title)", "cost": \(cost), "time": "\(time)",
         "is_running": \(isRunning), "is_deleted": \(isDeleted)}
        """
    }

    @Test
    func `decodes a single page fully within the limit`() async throws {
        let body = Self.page(
            records: [
                Self.record(id: "s1", title: "Task A", cost: 5, time: "2026-06-30T10:00:00Z"),
                Self.record(id: "s2", title: "Task B", cost: 3, time: "2026-06-29T10:00:00Z"),
            ].joined(separator: ","),
            total: 2)

        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "ai.zoom.us")
            #expect(request.url?.path == "/ai-computer/api/v1/credits/history")
            #expect(request.url?.query?.contains("app_id=demo_app") == true)
            #expect(request.url?.query?.contains("page=0") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://zoommate.zoom.us")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://zoommate.zoom.us")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(
            authorization: "Bearer fake-token",
            headers: ["Origin": "https://attacker.example", "Referer": "https://attacker.example/path"])
        let snapshot = try await ZoomMateCreditsHistoryFetcher.fetch(
            context: context,
            startTime: Self.startTime,
            endTime: Self.now,
            now: Self.now,
            transport: stub)

        #expect(snapshot.records.count == 2)
        let requestCount = await stub.requests().count
        #expect(requestCount == 1)
    }

    @Test
    func `paginates across multiple pages until total is satisfied`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let query = request.url?.query ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if query.contains("page=0") {
                let body = Self.page(
                    records: (0..<50).map {
                        Self.record(id: "s\($0)", title: "Task \($0)", cost: 1, time: "2026-06-30T10:00:00Z")
                    }.joined(separator: ","),
                    total: 55)
                return (Data(body.utf8), response)
            }
            #expect(query.contains("page=1"))
            let body = Self.page(
                records: (50..<55).map {
                    Self.record(id: "s\($0)", title: "Task \($0)", cost: 1, time: "2026-06-29T10:00:00Z")
                }.joined(separator: ","),
                total: 55)
            return (Data(body.utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        let snapshot = try await ZoomMateCreditsHistoryFetcher.fetch(
            context: context,
            startTime: Self.startTime,
            endTime: Self.now,
            now: Self.now,
            transport: stub)

        #expect(snapshot.records.count == 55)
        let requestCount = await stub.requests().count
        #expect(requestCount == 2)
    }

    @Test
    func `stops pagination early when a page returns no records`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let body = Self.page(records: "", total: 1000)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        let snapshot = try await ZoomMateCreditsHistoryFetcher.fetch(
            context: context,
            startTime: Self.startTime,
            endTime: Self.now,
            now: Self.now,
            transport: stub)

        #expect(snapshot.records.isEmpty)
        let requestCount = await stub.requests().count
        #expect(requestCount == 1)
    }

    @Test
    func `stops pagination early when a page is entirely older than startTime`() async throws {
        // `total: 1000` implies many more pages exist, but every record on page 0 is already
        // older than `startTime` — the defensive date-boundary stop (design.md D2) should break
        // before requesting page 1, regardless of what `total`/`maxPages` would otherwise allow.
        let staleTime = Self.startTime.addingTimeInterval(-24 * 3600) // 1 day before the window.
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.query?.contains("page=0") == true)
            let body = Self.page(
                records: (0..<50).map {
                    Self.record(
                        id: "s\($0)",
                        title: "Stale \($0)",
                        cost: 1,
                        time: ISO8601DateFormatter().string(from: staleTime))
                }.joined(separator: ","),
                total: 1000)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        let snapshot = try await ZoomMateCreditsHistoryFetcher.fetch(
            context: context,
            startTime: Self.startTime,
            endTime: Self.now,
            now: Self.now,
            transport: stub)

        #expect(snapshot.records.count == 50)
        let requestCount = await stub.requests().count
        #expect(requestCount == 1)
    }

    @Test
    func `unauthorized response maps to invalidCredentials`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{\"detail\": \"unauthorized\"}".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateCreditsHistoryFetcher.fetch(
                context: context,
                startTime: Self.startTime,
                endTime: Self.now,
                now: Self.now,
                transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `other server error maps to apiError`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data("boom".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateCreditsHistoryFetcher.fetch(
                context: context,
                startTime: Self.startTime,
                endTime: Self.now,
                now: Self.now,
                transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.apiError = error else { return false }
            return true
        }
    }

    @Test
    func `malformed body surfaces parseFailed`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"unexpected\": true}".utf8), response)
        }

        let context = ZoomMateUsageFetcher.RequestContext(authorization: "Bearer fake-token")
        await #expect {
            _ = try await ZoomMateCreditsHistoryFetcher.fetch(
                context: context,
                startTime: Self.startTime,
                endTime: Self.now,
                now: Self.now,
                transport: stub)
        } throws: { error in
            guard case ZoomMateUsageError.parseFailed = error else { return false }
            return true
        }
    }

    // MARK: - Daily aggregation

    @Test
    func `daily breakdown sums cost per calendar day and sorts ascending`() {
        let records: [ZoomMateCreditHistoryRecord] = [
            ZoomMateCreditHistoryRecord(
                sessionID: "s1",
                title: "A",
                cost: 5,
                time: "2026-06-30T10:00:00Z",
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s2",
                title: "B",
                cost: 3,
                time: "2026-06-30T20:00:00Z",
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s3",
                title: "C",
                cost: 2,
                time: "2026-06-29T10:00:00Z",
                isRunning: false,
                isDeleted: false),
        ]
        let snapshot = ZoomMateCreditsHistorySnapshot(records: records, updatedAt: Self.now)
        let breakdown = snapshot.dailyBreakdown(calendar: Self.utcCalendar)

        #expect(breakdown.count == 2)
        #expect(breakdown[0].day == "2026-06-29")
        #expect(breakdown[0].totalCreditsUsed == 2)
        #expect(breakdown[1].day == "2026-06-30")
        #expect(breakdown[1].totalCreditsUsed == 8)
    }

    @Test
    func `daily breakdown excludes deleted records`() {
        let records: [ZoomMateCreditHistoryRecord] = [
            ZoomMateCreditHistoryRecord(
                sessionID: "s1",
                title: "A",
                cost: 5,
                time: "2026-06-30T10:00:00Z",
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s2",
                title: "B (deleted)",
                cost: 100,
                time: "2026-06-30T11:00:00Z",
                isRunning: false,
                isDeleted: true),
        ]
        let snapshot = ZoomMateCreditsHistorySnapshot(records: records, updatedAt: Self.now)
        let breakdown = snapshot.dailyBreakdown(calendar: Self.utcCalendar)

        #expect(breakdown.count == 1)
        #expect(breakdown[0].totalCreditsUsed == 5)
    }

    @Test
    func `daily breakdown includes running sessions`() {
        let records: [ZoomMateCreditHistoryRecord] = [
            ZoomMateCreditHistoryRecord(
                sessionID: "s1",
                title: "Still running",
                cost: 1.5,
                time: "2026-06-30T10:00:00Z",
                isRunning: true,
                isDeleted: false),
        ]
        let snapshot = ZoomMateCreditsHistorySnapshot(records: records, updatedAt: Self.now)
        let breakdown = snapshot.dailyBreakdown(calendar: Self.utcCalendar)

        #expect(breakdown.count == 1)
        #expect(breakdown[0].totalCreditsUsed == 1.5)
    }

    @Test
    func `daily breakdown skips records with unparseable time or negative cost`() {
        let records: [ZoomMateCreditHistoryRecord] = [
            ZoomMateCreditHistoryRecord(
                sessionID: "s1",
                title: "Bad time",
                cost: 5,
                time: "not-a-date",
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s2",
                title: "Negative cost",
                cost: -1,
                time: "2026-06-30T10:00:00Z",
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s3",
                title: "Missing time",
                cost: 2,
                time: nil,
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s4",
                title: "Missing cost",
                cost: nil,
                time: "2026-06-30T10:00:00Z",
                isRunning: false,
                isDeleted: false),
        ]
        let snapshot = ZoomMateCreditsHistorySnapshot(records: records, updatedAt: Self.now)
        let breakdown = snapshot.dailyBreakdown(calendar: Self.utcCalendar)

        #expect(breakdown.isEmpty)
    }

    @Test
    func `daily breakdown returns empty for no records`() {
        let snapshot = ZoomMateCreditsHistorySnapshot(records: [], updatedAt: Self.now)
        #expect(snapshot.dailyBreakdown(calendar: Self.utcCalendar).isEmpty)
    }

    @Test
    func `daily breakdown excludes records older than the trailing 30-day window`() throws {
        // Fixed `now`; one record just inside the 30-day window, one just outside it.
        let fixedNow = try #require(Self.utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 12)))
        let withinWindow = "2026-06-05T10:00:00Z" // 29 days before `now` -> included.
        let outsideWindow = "2026-06-03T10:00:00Z" // 31 days before `now` -> excluded.
        let records: [ZoomMateCreditHistoryRecord] = [
            ZoomMateCreditHistoryRecord(
                sessionID: "s1",
                title: "Recent",
                cost: 5,
                time: withinWindow,
                isRunning: false,
                isDeleted: false),
            ZoomMateCreditHistoryRecord(
                sessionID: "s2",
                title: "Stale",
                cost: 100,
                time: outsideWindow,
                isRunning: false,
                isDeleted: false),
        ]
        let snapshot = ZoomMateCreditsHistorySnapshot(records: records, updatedAt: fixedNow)
        let breakdown = snapshot.dailyBreakdown(calendar: Self.utcCalendar, now: fixedNow)

        #expect(breakdown.count == 1)
        #expect(breakdown[0].day == "2026-06-05")
        #expect(breakdown[0].totalCreditsUsed == 5)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Pacing verdict

    @Test
    func `pacing verdict reports onTrack when usage matches elapsed cycle fraction`() throws {
        // Cycle: 100,000s long; now is 50,000s in (50% elapsed); used = 50% of budget.
        let cycleStart = Self.now.addingTimeInterval(-50000)
        let cycleEnd = Self.now.addingTimeInterval(50000)
        let status = ZoomMateCreditStatus(
            budgetCap: 1000,
            usedCredit: 500,
            remainingCredit: 500,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: Int64(cycleStart.timeIntervalSince1970 * 1000),
            cycleEndDate: Int64(cycleEnd.timeIntervalSince1970 * 1000),
            isQuotaAvailable: true,
            isUnlimited: false)

        let pace = try #require(status.pacingVerdict(now: Self.now))
        #expect(pace.stage == .onTrack)
    }

    @Test
    func `pacing verdict reports behind when usage is well below elapsed cycle fraction`() throws {
        let cycleStart = Self.now.addingTimeInterval(-50000)
        let cycleEnd = Self.now.addingTimeInterval(50000)
        let status = ZoomMateCreditStatus(
            budgetCap: 1000,
            usedCredit: 100,
            remainingCredit: 900,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: Int64(cycleStart.timeIntervalSince1970 * 1000),
            cycleEndDate: Int64(cycleEnd.timeIntervalSince1970 * 1000),
            isQuotaAvailable: true,
            isUnlimited: false)

        let pace = try #require(status.pacingVerdict(now: Self.now))
        #expect(pace.stage == .behind || pace.stage == .farBehind || pace.stage == .slightlyBehind)
        #expect(pace.deltaPercent < 0)
    }

    @Test
    func `pacing verdict reports ahead when usage is well above elapsed cycle fraction`() throws {
        let cycleStart = Self.now.addingTimeInterval(-50000)
        let cycleEnd = Self.now.addingTimeInterval(50000)
        let status = ZoomMateCreditStatus(
            budgetCap: 1000,
            usedCredit: 900,
            remainingCredit: 100,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: Int64(cycleStart.timeIntervalSince1970 * 1000),
            cycleEndDate: Int64(cycleEnd.timeIntervalSince1970 * 1000),
            isQuotaAvailable: true,
            isUnlimited: false)

        let pace = try #require(status.pacingVerdict(now: Self.now))
        #expect(pace.stage == .ahead || pace.stage == .farAhead || pace.stage == .slightlyAhead)
        #expect(pace.deltaPercent > 0)
    }

    @Test
    func `pacing verdict is nil for unlimited plans`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 1000,
            usedCredit: 500,
            remainingCredit: 500,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: Int64(Self.now.addingTimeInterval(-50000).timeIntervalSince1970 * 1000),
            cycleEndDate: Int64(Self.now.addingTimeInterval(50000).timeIntervalSince1970 * 1000),
            isQuotaAvailable: true,
            isUnlimited: true)

        #expect(status.pacingVerdict(now: Self.now) == nil)
    }

    @Test
    func `pacing verdict is nil when cycle dates are missing`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 1000,
            usedCredit: 500,
            remainingCredit: 500,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: nil,
            cycleEndDate: nil,
            isQuotaAvailable: true,
            isUnlimited: false)

        #expect(status.pacingVerdict(now: Self.now) == nil)
    }

    @Test
    func `pacing verdict is nil when budget cap is zero`() {
        let status = ZoomMateCreditStatus(
            budgetCap: 0,
            usedCredit: 0,
            remainingCredit: 0,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: Int64(Self.now.addingTimeInterval(-50000).timeIntervalSince1970 * 1000),
            cycleEndDate: Int64(Self.now.addingTimeInterval(50000).timeIntervalSince1970 * 1000),
            isQuotaAvailable: false,
            isUnlimited: false)

        #expect(status.pacingVerdict(now: Self.now) == nil)
    }

    @Test
    func `ZoomMateCreditsHistorySnapshot pacingVerdict delegates to its attached creditStatus`() {
        let cycleStart = Self.now.addingTimeInterval(-50000)
        let cycleEnd = Self.now.addingTimeInterval(50000)
        let status = ZoomMateCreditStatus(
            budgetCap: 1000,
            usedCredit: 500,
            remainingCredit: 500,
            overageCredit: 0,
            allowOverage: false,
            cycleStartDate: Int64(cycleStart.timeIntervalSince1970 * 1000),
            cycleEndDate: Int64(cycleEnd.timeIntervalSince1970 * 1000),
            isQuotaAvailable: true,
            isUnlimited: false)
        let snapshot = ZoomMateCreditsHistorySnapshot(records: [], creditStatus: status, updatedAt: Self.now)

        #expect(snapshot.pacingVerdict(now: Self.now)?.stage == .onTrack)
    }

    @Test
    func `ZoomMateCreditsHistorySnapshot pacingVerdict is nil without an attached creditStatus`() {
        let snapshot = ZoomMateCreditsHistorySnapshot(records: [], updatedAt: Self.now)
        #expect(snapshot.pacingVerdict(now: Self.now) == nil)
    }
}
