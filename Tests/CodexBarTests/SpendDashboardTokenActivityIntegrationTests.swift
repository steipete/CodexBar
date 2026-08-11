import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct SpendDashboardTokenActivityIntegrationTests {
    @Test
    func `shared Codex activity keeps partial store coverage through source and model`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = Self.scannerOptions(for: env)
        Self.installCache(
            in: env,
            options: options,
            scanSinceKey: "2026-04-06",
            scanUntilKey: "2026-04-08",
            days: [
                "2026-04-06": ["fixture-model": [7, 3, 11]],
                "2026-04-08": [
                    "fixture-model": [13, 2, 5],
                    "fixture-secondary": [4, 1, 2],
                ],
            ])

        let account = Self.account(homePath: env.codexHomeRoot.path)
        let result = await Self.load(
            account: account,
            now: now,
            snapshot: Self.snapshot(
                now: now,
                historyCoverageIsEstablished: true,
                daily: [Self.entry(day: "2026-04-08", tokens: 999, cost: 4)]),
            cacheRoot: env.cacheRoot)

        let input = try #require(result.inputs.first)
        #expect(result.failedSourceIDs.isEmpty)
        #expect(input.tokenActivityCache?.coverageSinceKey == "2026-04-06")
        #expect(input.tokenActivityCache?.coverageUntilKey == "2026-04-08")
        #expect(input.tokenActivityCache?.daily.map(\.totalTokens) == [18, 24])

        let model = SpendDashboardModel.build(
            inputs: result.inputs,
            requestedDays: 30,
            now: now,
            calendar: options.calendar)
        let dayBeforeCoverage = try #require(Self.day(now, offset: -3, calendar: options.calendar))
        let firstCoveredDay = try #require(Self.day(now, offset: -2, calendar: options.calendar))
        let uncoveredGap = try #require(Self.day(now, offset: -1, calendar: options.calendar))

        #expect(model.tokenActivity.count == SpendDashboardModel.tokenActivityDayCount)
        #expect(model.tokenActivity.compactMap(\.totalTokens).count == 3)
        #expect(Self.tokens(on: dayBeforeCoverage, in: model, calendar: options.calendar) == nil)
        #expect(Self.tokens(on: firstCoveredDay, in: model, calendar: options.calendar) == 18)
        #expect(Self.tokens(on: uncoveredGap, in: model, calendar: options.calendar) == 0)
        #expect(Self.tokens(on: now, in: model, calendar: options.calendar) == 24)
    }

    @Test
    func `empty established and unavailable shared activity retain distinct dashboard semantics`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = Self.scannerOptions(for: env)
        Self.installCache(
            in: env,
            options: options,
            scanSinceKey: "2026-04-06",
            scanUntilKey: "2026-04-08",
            days: [:])
        let account = Self.account(homePath: env.codexHomeRoot.path)
        let unknownSnapshot = Self.snapshot(
            now: now,
            historyCoverageIsEstablished: false,
            daily: [])

        let emptyResult = await Self.load(
            account: account,
            now: now,
            snapshot: unknownSnapshot,
            cacheRoot: env.cacheRoot)
        let emptyModel = SpendDashboardModel.build(
            inputs: emptyResult.inputs,
            requestedDays: 30,
            now: now,
            calendar: options.calendar)
        let beforeCoverage = try #require(Self.day(now, offset: -3, calendar: options.calendar))

        #expect(emptyResult.failedSourceIDs.isEmpty)
        #expect(emptyResult.inputs.first?.tokenActivityCache?.daily.isEmpty == true)
        #expect(emptyModel.tokenActivity.count == SpendDashboardModel.tokenActivityDayCount)
        #expect(Self.tokens(on: beforeCoverage, in: emptyModel, calendar: options.calendar) == nil)
        #expect(emptyModel.tokenActivity.suffix(3).allSatisfy { $0.totalTokens == 0 })

        Self.installCache(
            in: env,
            options: options,
            scanSinceKey: nil,
            scanUntilKey: nil,
            days: [:])
        let unavailableResult = await Self.load(
            account: account,
            now: now,
            snapshot: unknownSnapshot,
            cacheRoot: env.cacheRoot)
        let unavailableModel = SpendDashboardModel.build(
            inputs: unavailableResult.inputs,
            requestedDays: 30,
            now: now,
            calendar: options.calendar)

        #expect(!unavailableResult.inputs.isEmpty)
        #expect(unavailableResult.failedSourceIDs.isEmpty)
        #expect(unavailableResult.inputs.first?.tokenActivityCache == nil)
        #expect(unavailableModel.tokenActivity.count == SpendDashboardModel.tokenActivityDayCount)
        #expect(unavailableModel.tokenActivity.allSatisfy { $0.totalTokens == nil })
    }

    private static func load(
        account: CodexSpendScanRequest,
        now: Date,
        snapshot: CostUsageTokenSnapshot,
        cacheRoot: URL) async -> SpendDashboardLoadResult
    {
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: ["\(account.id)|\(account.cacheIdentity)"]),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: now,
            force: false)
        return await SpendDashboardSource.load(
            request,
            cacheRootResolver: { _ in cacheRoot },
            codexSnapshotLoader: { context in
                #expect(context.historyDays == request.historyDays)
                #expect(context.cacheRoot == cacheRoot)
                return snapshot
            })
    }

    private static func installCache(
        in env: CostUsageTestEnvironment,
        options: CostUsageScanner.Options,
        scanSinceKey: String?,
        scanUntilKey: String?,
        days: [String: [String: [Int]]])
    {
        var cache = CostUsageCache()
        cache.scanSinceKey = scanSinceKey
        cache.scanUntilKey = scanUntilKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.days = days
        if !days.isEmpty {
            let path = env.codexSessionsRoot.appendingPathComponent("fixture.jsonl").path
            cache.files[path] = CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: 1,
                days: days,
                parsedBytes: 1,
                codexScanComplete: true)
        }
        CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            cache: cache,
            calendar: options.calendar)
    }

    private static func scannerOptions(for env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
    }

    private static func account(homePath: String) -> CodexSpendScanRequest {
        CodexSpendScanRequest(
            id: "synthetic",
            displayName: "Codex",
            source: .profileHome(path: homePath),
            homePath: homePath,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "synthetic-cache")
    }

    private static func snapshot(
        now: Date,
        historyCoverageIsEstablished: Bool,
        daily: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            daily: daily,
            updatedAt: now)
    }

    private static func entry(day: String, tokens: Int, cost: Double?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func day(_ now: Date, offset: Int, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
    }

    private static func tokens(on day: Date, in model: SpendDashboardModel, calendar: Calendar) -> Int? {
        model.tokenActivity.first { calendar.isDate($0.day, inSameDayAs: day) }?.totalTokens
    }
}
