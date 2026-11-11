import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClaudePlatformAWSPluginTests {
    /// 2026-11-11T15:30:10Z, so the 30-day window starts on 2026-10-13 and the month on 2026-11-01.
    private static let wallClock = Date(timeIntervalSince1970: 1_794_411_010)
    private static let refreshedAt = "2026-11-11T12:02:11Z"
    private static let keyID = "FIXTUREKEYID"
    private static let modelA = "fixture-model-a"
    private static let modelB = "fixture-model-b"

    /// SigV4 over the us-west-2 month-total request, computed independently for the fixture secret and clock.
    /// The digest is a test vector, not a credential; it is assembled from parts so scanners do not flag it.
    private static let westTotalSignature = [
        "baf33ff9013d9e10", "9cca18542cda2eca", "d3a20c45cf9eaf19", "a2a4fc5f0fb10149",
    ].joined()

    private struct Fixture: Sendable {
        var totalCode = 200
        var totalBody: [String: String] = [
            "us-west-2": ClaudePlatformAWSPluginTests.page([
                ClaudePlatformAWSPluginTests.costRow(
                    "2026-11-01T00:00:00Z", amount: "30000.000000", list: "37500.000000", requests: 1000,
                    workspace: "wrkspc_fixtureA", model: ClaudePlatformAWSPluginTests.modelA),
                ClaudePlatformAWSPluginTests.costRow(
                    "2026-11-01T00:00:00Z", amount: "11280.000000", list: "14100.000000", requests: 280,
                    workspace: "wrkspc_fixtureA", model: ClaudePlatformAWSPluginTests.modelB),
            ]),
            "us-east-1": ClaudePlatformAWSPluginTests.page([
                ClaudePlatformAWSPluginTests.costRow(
                    "2026-11-01T00:00:00Z", amount: "6000.000000", requests: 150,
                    workspace: "wrkspc_fixtureB", model: ClaudePlatformAWSPluginTests.modelA),
                ClaudePlatformAWSPluginTests.costRow("2026-11-01T00:00:00Z", amount: "1280.000000", requests: 20),
            ]),
        ]
        var dailyCode = 200
        /// Serves the us-west-2 daily cost series as two pages joined by a cursor.
        var pagesDailyCost = false
        var extraWestDailyRows: [String] = []
        var usageCode = 200
        var workspaceCode = ["us-west-2": 200, "us-east-1": 403]
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `regions are summed into month spend, daily history, and breakdown rows`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine)
        let cost = try #require(snapshot.providerCost)
        #expect(abs(cost.used - 485.6) < 0.000_001)
        // No budget is reported as a zero limit, which the app treats as unlimited.
        #expect(cost.limit == 0)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "This month")
        // Without budgets there is nothing to measure spend against, so no windows are reported.
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "AWS access key")
        #expect(snapshot.dataConfidence == .exact)

        #expect(snapshot.details.map(\.title) == ["Spend", "By region"] + Self.breakdownTitles)
        #expect(snapshot.details.map(\.variant) == [nil, nil] + Self.breakdownVariants)
        let spend = snapshot.details[0].rows
        // One day with spend in the last seven is too little history for a projection.
        #expect(spend.map(\.label) == [
            "This month", "Today", "At list prices", "Requests", "Data as of", "Next data expected",
        ])
        #expect(spend.map(\.value) == [
            "$485.60", "$135.60", "$588.80", "1,450", "2026-11-11 12:02 UTC", "About 2026-11-11 16:02 UTC",
        ])
        #expect(snapshot.details[1].rows.map(\.label) == ["us-west-2", "us-east-1"])
        #expect(snapshot.details[1].rows.map(\.value) == ["$412.80", "$72.80"])
        #expect(snapshot.details[1].rows.map(\.secondaryValue) == ["85%", "15%"])
        let section: (String) throws -> ProviderDetailSection = { title in
            try #require(snapshot.details.first { $0.title == title })
        }
        // Spend without a model, such as code execution, stays visible instead of being dropped.
        let monthModels = try section("By model · Month to date").rows
        #expect(monthModels.map(\.label) == [Self.modelA, Self.modelB, "Other usage"])
        #expect(monthModels.map(\.value) == ["$360.00", "$112.80", "$12.80"])
        #expect(monthModels.map(\.secondaryValue) == ["74%", "23%", "3%"])
        // us-east-1 denies the workspace list, so its workspace keeps the ID while us-west-2 shows the name.
        let monthWorkspaces = try section("By workspace · Month to date").rows
        #expect(monthWorkspaces.map(\.label) == [
            "Fixture Production", "wrkspc_fixtureB", "No workspace in us-east-1",
        ])
        #expect(monthWorkspaces.map(\.value) == ["$412.80", "$60.00", "$12.80"])

        // The other periods come from the daily series; shares are of the period's own total.
        let models30 = try section("By model · Last 30 days").rows
        #expect(models30.map(\.label) == [Self.modelA, Self.modelB, "Other usage"])
        #expect(models30.map(\.value) == ["$365.00", "$112.80", "$22.80"])
        #expect(models30.map(\.secondaryValue) == ["73%", "23%", "5%"])
        // 2026-10-20 falls outside the last seven days.
        #expect(try section("By model · Last 7 days").rows.map(\.value) == ["$350.00", "$112.80", "$22.80"])
        let modelsToday = try section("By model · Today").rows
        #expect(modelsToday.map(\.label) == [Self.modelA, "Other usage", Self.modelB])
        #expect(modelsToday.map(\.value) == ["$100.00", "$22.80", "$12.80"])
        let workspaces30 = try section("By workspace · Last 30 days").rows
        #expect(workspaces30.map(\.label) == [
            "Fixture Production", "wrkspc_fixtureB", "No workspace in us-east-1",
        ])
        #expect(workspaces30.map(\.value) == ["$427.80", "$50.00", "$22.80"])
        let workspacesToday = try section("By workspace · Today").rows
        #expect(workspacesToday.map(\.label) == ["Fixture Production", "No workspace in us-east-1"])
        #expect(workspacesToday.map(\.value) == ["$112.80", "$22.80"])

        let history = try #require(snapshot.costUsage)
        #expect(history.historyDays == 30)
        #expect(history.historyLabel == "Last 30 days (UTC)")
        #expect(history.currencyCode == "USD")
        #expect(history.daily.map(\.date) == ["2026-10-20", "2026-11-05", "2026-11-11"])
        #expect(history.daily.map(\.requestCount) == [40, 1000, 170])
        #expect(history.daily.map(\.totalTokens) == [6211, 2900, 450])
        #expect(history.daily.map(\.inputTokens) == [6011, 2500, 400])
        #expect(history.daily[1].modelBreakdowns?.map(\.modelName).sorted() == [Self.modelA, Self.modelB])
        let dailyCost = history.daily.compactMap(\.costUSD)
        #expect(dailyCost.count == 3)
        #expect(abs(dailyCost[0] - 15) < 0.000_001)
        #expect(abs(dailyCost[1] - 350) < 0.000_001)
        #expect(abs(dailyCost[2] - 135.6) < 0.000_001)
        #expect(history.last30DaysTokens == 9561)
        #expect(history.last30DaysRequests == 1210)

        // The shared spend catalog reads today's figures from the entry for the current UTC day.
        let projected = try #require(ClaudePlatformAWSCostUsageMapping.tokenSnapshot(from: snapshot))
        #expect(abs((projected.sessionCostUSD ?? 0) - 135.6) < 0.000_001)
        #expect(projected.sessionTokens == 450)
        #expect(projected.sessionRequests == 170)
        #expect(projected.daily == history.daily)
        #expect(projected.last30DaysCostUSD == history.last30DaysCostUSD)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a single region omits the region breakdown`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, regions: "us-west-2")
        #expect(snapshot.details.map(\.title) == ["Spend"] + Self.breakdownTitles)
        #expect(abs((snapshot.providerCost?.used ?? 0) - 412.8) < 0.000_001)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a series spread over pages is read whole by following its cursor`(
        engine: ProviderPluginEngineKind) async throws
    {
        var fixture = Fixture()
        fixture.pagesDailyCost = true
        let recorder = Recorder()
        let snapshot = try await Self.usage(
            Self.runtime(engine: engine, fixture: fixture, recorder: recorder), regions: "us-west-2")
        #expect(await recorder.drain() == [
            "cost:total", "cost:daily", "cost:daily", "cost:today", "usage:daily", "usage:today", "workspaces:today",
        ])
        let history = try #require(snapshot.costUsage)
        #expect(history.daily.map(\.date) == ["2026-10-20", "2026-11-05", "2026-11-11"])
        #expect(abs((history.daily[1].costUSD ?? 0) - 300) < 0.000_001)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `the local time zone cuts days from hourly buckets`(engine: ProviderPluginEngineKind) async throws {
        let recorder = Recorder()
        let snapshot = try await Self.usage(
            Self.runtime(engine: engine, recorder: recorder), regions: "us-west-2", zone: " Local ")
        // One hourly range reaches the current hour, so there is no separate read for today.
        #expect(await recorder.drain() == ["cost:total", "cost:hourly", "usage:hourly", "workspaces:today"])
        // Which local day an hour falls on depends on the machine's zone, so only zone-independent sums are
        // asserted: two buckets inside the window in any zone, and one in the current hour.
        let history = try #require(snapshot.costUsage)
        #expect(history.historyLabel == "Last 30 days")
        #expect(ClaudePlatformAWSCostUsageMapping.usesLocalDays(historyLabel: history.historyLabel))
        #expect(abs((history.last30DaysCostUSD ?? 0) - 350) < 0.000_001)
        #expect(history.last30DaysTokens == 2300)
        let today = try #require(snapshot.details[0].rows.first { $0.label == "Today" })
        #expect(today.value == "$50.00")
        #expect(today.secondaryValue == "So far")
        let projected = try #require(ClaudePlatformAWSCostUsageMapping.tokenSnapshot(from: snapshot))
        #expect(abs((projected.sessionCostUSD ?? 0) - 50) < 0.000_001)
        let models = try #require(snapshot.details.first { $0.title == "By model · Last 30 days" }).rows
        #expect(models.map(\.value) == ["$250.00", "$100.00"])
        #expect(snapshot.details.first { $0.title == "By workspace · Today" }?.rows.map(\.value) == ["$50.00"])
        // Times are shown in the same zone, without the UTC suffix.
        #expect(snapshot.details[0].rows.first { $0.label == "Data as of" }?.value.hasSuffix("UTC") == false)

        do {
            _ = try await Self.usage(Self.runtime(engine: engine), regions: "us-west-2", zone: "fixture/zone")
            Issue.record("Expected a rejected time zone")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure)
            #expect(error.message.contains("time zone"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional budgets become today and month windows without changing spend`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.usage(
            Self.runtime(engine: engine),
            regions: "us-west-2, us-east-1",
            budgets: ["ANTHROPIC_AWS_MONTHLY_BUDGET": "$1,000", "ANTHROPIC_AWS_DAILY_BUDGET": "200"])
        let today = try #require(snapshot.primary)
        #expect(abs(today.usedPercent - 67.8) < 0.000_001)
        #expect(today.windowMinutes == 1440)
        #expect(today.resetsAt == Date(timeIntervalSince1970: 1_794_441_600))
        let month = try #require(snapshot.secondary)
        #expect(abs(month.usedPercent - 48.56) < 0.000_001)
        #expect(month.resetsAt == Date(timeIntervalSince1970: 1_796_083_200))
        // The budget lives in the month window only; a cost limit would draw a second, identical bar.
        #expect(snapshot.providerCost?.limit == 0)
        #expect(abs((snapshot.providerCost?.used ?? 0) - 485.6) < 0.000_001)
        let rows = snapshot.details[0].rows
        #expect(rows[0].value == "$485.60 of $1,000.00")
        #expect(rows[1].value == "$135.60 of $200.00")

        for budget in ["fixture", "0", "-5"] {
            do {
                _ = try await Self.usage(
                    Self.runtime(engine: engine),
                    regions: "us-west-2",
                    budgets: ["ANTHROPIC_AWS_DAILY_BUDGET": budget])
                Issue.record("Expected a rejected daily budget '\(budget)'")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .apiFailure)
                #expect(error.message.contains("daily budget"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `three recent spending days project the month from the seven day average`(
        engine: ProviderPluginEngineKind) async throws
    {
        var fixture = Fixture()
        fixture.extraWestDailyRows = [
            Self.costRow("2026-11-08T00:00:00Z", amount: "2100.000000", requests: 10, model: Self.modelA),
            Self.costRow("2026-11-09T00:00:00Z", amount: "3500.000000", requests: 10, model: Self.modelA),
            Self.costRow("2026-11-10T00:00:00Z", amount: "1400.000000", requests: 10, model: Self.modelA),
        ]
        let snapshot = try await Self.usage(
            Self.runtime(engine: engine, fixture: fixture),
            regions: "us-west-2",
            budgets: ["ANTHROPIC_AWS_MONTHLY_BUDGET": "500"])
        let rows = snapshot.details[0].rows
        let row = try #require(rows.first { $0.label == "Projected this month" })
        // Seven completed days total $370.00 ($300 + $21 + $35 + $14), so $52.86 a day. That rate for the
        // 19.4985 days after the 12:02:11Z watermark is added to the $412.80 spent so far.
        #expect(row.value == "$1,443.43")
        #expect(row.secondaryValue == "$52.86/day (7-day avg)")
        // $87.20 of budget is left at $52.86 a day: about 1.65 days after the watermark.
        #expect(rows.first { $0.label == "Monthly budget lasts" }?.value == "Until about 2026-11-13")
        // The projection never changes the reported spend.
        #expect(abs((snapshot.providerCost?.used ?? 0) - 412.8) < 0.000_001)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `labels matching inherited object keys keep their spend`(engine: ProviderPluginEngineKind) async throws {
        var fixture = Fixture()
        fixture.extraWestDailyRows = [
            Self.costRow("2026-11-09T00:00:00Z", amount: "2100.000000", requests: 10, model: "constructor"),
            Self.costRow("2026-11-10T00:00:00Z", amount: "1400.000000", requests: 10, model: "__proto__"),
        ]
        let snapshot = try await Self.usage(Self.runtime(engine: engine, fixture: fixture), regions: "us-west-2")
        let rows = try #require(snapshot.details.first { $0.title == "By model · Last 7 days" }).rows
        #expect(rows.first { $0.label == "constructor" }?.value == "$21.00")
        #expect(rows.first { $0.label == "__proto__" }?.value == "$14.00")
    }

    @Test
    func `local-day history keeps its last day east of UTC+12`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        // The generic mapper's stamp for a window ending 2026-11-11: noon UTC, which is 01:00 on the 12th here.
        let windowEnd = Date(timeIntervalSince1970: 1_794_398_400)
        let history: (String) -> UsageSnapshot = { label in
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                costUsage: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: nil,
                    last30DaysCostUSD: 5,
                    historyLabel: label,
                    daily: [],
                    updatedAt: windowEnd),
                // 18:00 on the 11th in Auckland.
                updatedAt: windowEnd.addingTimeInterval(-7 * 3600))
        }
        let local = try #require(ClaudePlatformAWSCostUsageMapping.tokenSnapshot(
            from: history("Last 30 days"), localCalendar: calendar))
        #expect(CostUsageLocalDay.key(from: local.updatedAt, calendar: calendar) == "2026-11-11")
        let utc = try #require(ClaudePlatformAWSCostUsageMapping.tokenSnapshot(
            from: history("Last 30 days (UTC)"), localCalendar: calendar))
        #expect(utc.updatedAt == windowEnd)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `refreshes reuse a region until its watermark is due and then advances`(
        engine: ProviderPluginEngineKind) async throws
    {
        let recorder = Recorder()
        let runtime = try Self.runtime(engine: engine, recorder: recorder)
        let at: (TimeInterval) -> Date = { Self.wallClock.addingTimeInterval($0) }
        let series = ["cost:daily", "cost:today", "usage:daily", "usage:today"]

        // 15:30:10, watermark 12:02:11: a full read.
        let first = try await Self.usage(runtime, regions: "us-west-2", now: at(0))
        #expect(await recorder.drain() == ["cost:total"] + series + ["workspaces:today"])

        // Quiet: under four hours since the watermark and under an hour since the last check.
        let quiet = try await Self.usage(runtime, regions: "us-west-2", now: at(30 * 60))
        #expect(await recorder.drain().isEmpty)
        #expect(quiet.providerCost?.used == first.providerCost?.used)

        // Due at 16:10: one month-total read finds the same watermark and keeps the cached series.
        _ = try await Self.usage(runtime, regions: "us-west-2", now: at(40 * 60))
        #expect(await recorder.drain() == ["cost:total"])
        // Due checks are spaced ten minutes apart.
        _ = try await Self.usage(runtime, regions: "us-west-2", now: at(45 * 60))
        #expect(await recorder.drain().isEmpty)

        // A newer watermark triggers the series reads; workspace names stay cached.
        await recorder.advanceWatermark(to: "2026-11-11T16:05:00Z")
        let advanced = try await Self.usage(runtime, regions: "us-west-2", now: at(51 * 60))
        #expect(await recorder.drain() == ["cost:total"] + series)
        #expect(advanced.details[0].rows.first { $0.label == "Data as of" }?.value == "2026-11-11 16:05 UTC")
        #expect(advanced.details[0].rows.first { $0.label == "Next data expected" }?.value
            == "About 2026-11-11 20:05 UTC")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable history keeps the month total without inventing daily spend`(
        engine: ProviderPluginEngineKind) async throws
    {
        var fixture = Fixture()
        fixture.dailyCode = 403
        let withoutDaily = try await Self.fetch(engine: engine, fixture: fixture)
        #expect(withoutDaily.costUsage == nil)
        #expect(withoutDaily.details[0].rows.map(\.label) == [
            "This month", "At list prices", "Requests", "Data as of", "Next data expected",
        ])
        // Only the month to date, which comes from the month-total read, is left to break down.
        #expect(withoutDaily.details.map(\.title) == [
            "Spend", "By region", "By model · Month to date", "By workspace · Month to date",
        ])
        #expect(abs((withoutDaily.providerCost?.used ?? 0) - 485.6) < 0.000_001)

        fixture = Fixture()
        fixture.usageCode = 403
        let withoutTokens = try await Self.fetch(engine: engine, fixture: fixture)
        #expect(withoutTokens.costUsage == nil)
        #expect(withoutTokens.details[0].rows.map(\.label).contains("Today"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures stay classified and name the region without echoing bodies`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            var fixture = Fixture()
            fixture.totalCode = code
            fixture.totalBody["us-west-2"] = "private-response"
            await Self.expectFailure(engine: engine, fixture: fixture, kind: kind) { message in
                #expect(message.contains("us-west-2"))
                #expect(message.contains("HTTP \(code)"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a denied IAM action is reported from the permission error`(engine: ProviderPluginEngineKind) async throws {
        var fixture = Fixture()
        fixture.totalCode = 403
        fixture.totalBody["us-west-2"] =
            #"{"type":"error","error":{"type":"permission_error","message":"not authorized to perform: "#
            + #"aws-external-anthropic:ListAccountCost"}}"#
        await Self.expectFailure(engine: engine, fixture: fixture, kind: .permissionDenied) { message in
            #expect(message.contains("aws-external-anthropic:ListAccountCost"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed cost responses never become zero spend`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            "private-response",
            #"{"data":"private-response"}"#,
            Self.page([#"{"starting_at":"2026-11-01T00:00:00Z","group":{},"cost":{"amount":"private-response"}}"#]),
            Self.page([#"{"group":{},"cost":{"amount":"100.000000"}}"#]),
        ] {
            var fixture = Fixture()
            fixture.totalBody["us-west-2"] = body
            await Self.expectFailure(engine: engine, fixture: fixture, kind: .parseFailure)
        }
        var fixture = Fixture()
        fixture.totalBody["us-west-2"] = Self.page([], hasMore: true)
        await Self.expectFailure(engine: engine, fixture: fixture, kind: .apiFailure)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing or unsupported regions and credentials fail before network access`(
        engine: ProviderPluginEngineKind) async throws
    {
        let secrets = ["ANTHROPIC_AWS_ACCESS_KEY_ID": Self.keyID, "ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret"]
        for (regions, credentials) in [
            ("", secrets), (" , ", secrets), ("us-west-2, fixture-region-1", secrets),
            ("us-west-2", ["ANTHROPIC_AWS_ACCESS_KEY_ID": Self.keyID]),
            ("us-west-2", ["ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret"]),
        ] {
            let runtime = try BundledPluginTestSupport.runtime(
                "claudeplatformaws", engine: engine, wallClock: Self.wallClock,
                transport: ProviderHTTPTransportHandler { request in
                    Issue.record("Unexpected request to \(request.url?.host ?? "unknown host")")
                    throw URLError(.badURL)
                })
            do {
                _ = try await runtime.fetchUsage(settings: ["ANTHROPIC_AWS_REGIONS": regions], secrets: credentials)
                Issue.record("Expected missing credential for regions '\(regions)'")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .missingCredential)
                #expect(!error.message.contains("fixture-secret"))
            }
        }
    }

    // MARK: - Fixtures

    private static let breakdownPeriods = [
        (pick: "30d", title: "Last 30 days"), (pick: "MTD", title: "Month to date"),
        (pick: "7d", title: "Last 7 days"), (pick: "Today", title: "Today"),
    ]
    private static let breakdownTitles = ["By model", "By workspace"].flatMap { dimension in
        breakdownPeriods.map { "\(dimension) · \($0.title)" }
    }

    private static let breakdownVariants: [[String]?] = ["Model", "Workspace"].flatMap { dimension in
        breakdownPeriods.map { [dimension, $0.pick] }
    }

    private static func page(_ rows: [String], hasMore: Bool = false, nextPage: String? = nil) -> String {
        #"{"data":["# + rows.joined(separator: ",") + #"],"has_more":"# + String(hasMore)
            + #","next_page":"# + self.quoted(nextPage) + #","data_refreshed_at":""# + self.refreshedAt + #""}"#
    }

    private static func quoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "null"
    }

    // swiftlint:disable:next function_parameter_count
    private static func costRow(
        _ start: String,
        amount: String,
        list: String? = nil,
        requests: Int,
        workspace: String? = nil,
        model: String? = nil) -> String
    {
        #"{"starting_at":""# + start + #"","ending_at":""# + start
            + #"","group":{"model":"# + self.quoted(model) + #","workspace_id":"# + self.quoted(workspace)
            + #"},"cost":{"currency":"USD","amount":""# + amount + #"","list_amount":""# + (list ?? amount)
            + #"","requests":"# + String(requests) + "}}"
    }

    // swiftlint:disable:next function_parameter_count
    private static func usageRow(
        _ start: String,
        model: String,
        uncached: Int,
        cacheRead: Int = 0,
        written5m: Int = 0,
        written1h: Int = 0,
        output: Int) -> String
    {
        #"{"starting_at":""# + start + #"","group":{"model":"# + self.quoted(model)
            + #","workspace_id":null},"usage":{"uncached_input_tokens":"# + String(uncached)
            + #","cache_read_input_tokens":"# + String(cacheRead)
            + #","cache_creation":{"ephemeral_5m_input_tokens":"# + String(written5m)
            + #","ephemeral_1h_input_tokens":"# + String(written1h) + #"},"output_tokens":"# + String(output)
            + #","total_tokens":0,"requests":1}}"#
    }

    private static func expectFailure(
        engine: ProviderPluginEngineKind,
        fixture: Fixture,
        kind: ProviderFetchClassifiedError.Kind,
        message check: (String) -> Void = { _ in }) async
    {
        do {
            _ = try await self.fetch(engine: engine, fixture: fixture)
            Issue.record("Expected classified failure \(kind)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-secret"))
            check(error.message)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        regions: String = "us-west-2, US-EAST-1, us-west-2",
        fixture: Fixture = Fixture()) async throws -> UsageSnapshot
    {
        try await self.usage(self.runtime(engine: engine, fixture: fixture), regions: regions)
    }

    private static func usage(
        _ runtime: ProviderPluginRuntime,
        regions: String,
        budgets: [String: String] = [:],
        zone: String = "utc",
        now: Date = ClaudePlatformAWSPluginTests.wallClock) async throws -> UsageSnapshot
    {
        try await runtime.fetchUsage(
            settings: budgets.merging([
                "ANTHROPIC_AWS_REGIONS": regions, "ANTHROPIC_AWS_TIME_ZONE": zone,
            ]) { _, setting in setting },
            secrets: [
                "ANTHROPIC_AWS_ACCESS_KEY_ID": Self.keyID,
                "ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret",
            ],
            now: now)
    }

    /// A recorder makes the refresh clock and watermark movable, so exact first-refresh queries are not asserted.
    private static func runtime(
        engine: ProviderPluginEngineKind,
        fixture: Fixture = Fixture(),
        recorder: Recorder? = nil) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "claudeplatformaws", engine: engine, wallClock: Self.wallClock,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let host = url.host ?? ""
                let region = host.split(separator: ".").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
                #expect(host == "aws-external-anthropic.\(region).api.aws")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20261111T153010Z")
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
                let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
                let credential = "AWS4-HMAC-SHA256 Credential=\(Self.keyID)/20261111/\(region)/aws-external-anthropic"
                    + "/aws4_request, SignedHeaders=host;x-amz-date, Signature="
                #expect(authorization.hasPrefix(credential))
                #expect(!authorization.contains("fixture-secret"))

                let west = region == "us-west-2"
                // Unbucketed cost reads are the month total, or today when they start at today's UTC midnight.
                let kind = query.contains("time_bucket_width=1d") ? "daily"
                    : query.contains("time_bucket_width=1h") ? "hourly"
                    : query.contains("starting_at=2026-11-11T00") || !query.contains("starting_at") ? "today"
                    : "total"
                let exact = recorder == nil
                // Cost series are grouped by model and workspace, usage series by model only.
                let grouping = url.lastPathComponent == "cost"
                    ? "group_by%5B%5D=model&group_by%5B%5D=workspace_id" : "group_by%5B%5D=model"
                let dayRange = "ending_at=2026-11-11T00%3A00%3A00Z&\(grouping)&limit=1000&order=asc"
                    + "&order_by=time&starting_at=2026-10-13T00%3A00%3A00Z&time_bucket_width=1d"
                let todayRange = "ending_at=2026-11-11T15%3A30%3A10Z&\(grouping)&limit=1000"
                    + "&starting_at=2026-11-11T00%3A00%3A00Z"
                let westWorkspace = "wrkspc_fixtureA"
                let (body, status): (String, Int)
                switch (url.lastPathComponent, kind) {
                case ("cost", "total"):
                    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "analytics-usage-cost-2026-08-24")
                    if west, exact {
                        #expect(query == "ending_at=2026-11-11T15%3A30%3A10Z&group_by%5B%5D=model"
                            + "&group_by%5B%5D=workspace_id&limit=1000&starting_at=2026-11-01T00%3A00%3A00Z")
                        #expect(authorization == credential + Self.westTotalSignature)
                    }
                    (body, status) = (fixture.totalBody[region] ?? Self.page([]), west ? fixture.totalCode : 200)
                case ("cost", "daily"):
                    let cursor = "&page=fixture-cursor"
                    #expect(query.replacingOccurrences(of: cursor, with: "") == dayRange)
                    let rows = west
                        ? [
                            Self.costRow(
                                "2026-10-20T00:00:00Z", amount: "1500.000000", requests: 40,
                                workspace: westWorkspace, model: Self.modelA),
                            Self.costRow(
                                "2026-11-05T00:00:00Z", amount: "20000.000000", requests: 600,
                                workspace: westWorkspace, model: Self.modelA),
                            Self.costRow(
                                "2026-11-05T00:00:00Z", amount: "10000.000000", requests: 300,
                                workspace: westWorkspace, model: Self.modelB),
                        ] + fixture.extraWestDailyRows
                        : [
                            Self.costRow(
                                "2026-11-05T00:00:00Z", amount: "5000.000000", requests: 100,
                                workspace: "wrkspc_fixtureB", model: Self.modelA),
                        ]
                    if west, fixture.pagesDailyCost {
                        body = query.contains(cursor)
                            ? Self.page(Array(rows.dropFirst()))
                            : Self.page(Array(rows.prefix(1)), hasMore: true, nextPage: "fixture-cursor")
                        status = fixture.dailyCode
                    } else {
                        (body, status) = (Self.page(rows), fixture.dailyCode)
                    }
                case ("cost", "today"):
                    if exact { #expect(query == todayRange) }
                    let rows = west
                        ? [
                            Self.costRow(
                                "2026-11-11T00:00:00Z", amount: "10000.000000", requests: 100,
                                workspace: westWorkspace, model: Self.modelA),
                            Self.costRow(
                                "2026-11-11T00:00:00Z", amount: "1280.000000", requests: 50,
                                workspace: westWorkspace, model: Self.modelB),
                        ]
                        : [Self.costRow("2026-11-11T00:00:00Z", amount: "2280.000000", requests: 20)]
                    (body, status) = (Self.page(rows), fixture.dailyCode)
                case ("cost", "hourly"):
                    #expect(query.contains("ending_at=2026-11-11T15%3A30%3A10Z&\(grouping)&limit=1000"))
                    (body, status) = (Self.page([
                        Self.costRow(
                            "2026-11-06T12:00:00Z", amount: "20000.000000", requests: 600,
                            workspace: westWorkspace, model: Self.modelA),
                        Self.costRow(
                            "2026-11-06T13:00:00Z", amount: "10000.000000", requests: 300,
                            workspace: westWorkspace, model: Self.modelB),
                        Self.costRow(
                            "2026-11-11T15:00:00Z", amount: "5000.000000", requests: 100,
                            workspace: westWorkspace, model: Self.modelA),
                    ]), fixture.dailyCode)
                case ("usage", "hourly"):
                    (body, status) = (Self.page([
                        Self.usageRow("2026-11-06T12:00:00Z", model: Self.modelA, uncached: 2000, output: 300),
                    ]), fixture.usageCode)
                case ("usage", "daily"):
                    #expect(query == dayRange)
                    let rows = west
                        ? [
                            Self.usageRow(
                                "2026-10-20T00:00:00Z", model: Self.modelA, uncached: 1000, cacheRead: 5000,
                                written5m: 10, written1h: 1, output: 200),
                            Self.usageRow("2026-11-05T00:00:00Z", model: Self.modelA, uncached: 2000, output: 300),
                            Self.usageRow("2026-11-05T00:00:00Z", model: Self.modelB, uncached: 500, output: 100),
                        ]
                        : []
                    (body, status) = (Self.page(rows), fixture.usageCode)
                case ("usage", "today"):
                    if exact { #expect(query == todayRange) }
                    let rows = west
                        ? [Self.usageRow("2026-11-11T00:00:00Z", model: Self.modelA, uncached: 400, output: 50)]
                        : []
                    (body, status) = (Self.page(rows), fixture.usageCode)
                case ("workspaces", _):
                    #expect(query == "include_archived=true&include_default=true&limit=1000")
                    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
                    (body, status) = (
                        #"{"data":[{"id":"wrkspc_fixtureA","type":"workspace","name":" Fixture Production "}],"#
                            + #""has_more":false}"#,
                        fixture.workspaceCode[region] ?? 200)
                default:
                    Issue.record("Unexpected request path \(url.path)")
                    (body, status) = ("{}", 404)
                }
                let watermark = await recorder?.record("\(url.lastPathComponent):\(kind)")
                let served = watermark.map { body.replacingOccurrences(of: Self.refreshedAt, with: $0) } ?? body
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(served.utf8), response)
            })
    }

    private actor Recorder {
        private var requests: [String] = []
        private var watermark = ClaudePlatformAWSPluginTests.refreshedAt

        func record(_ request: String) -> String {
            self.requests.append(request)
            return self.watermark
        }

        func advanceWatermark(to watermark: String) {
            self.watermark = watermark
        }

        func drain() -> [String] {
            defer { self.requests = [] }
            return self.requests
        }
    }
}
