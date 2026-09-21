import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PiNativeProjectionTests {
    @Test
    func `fresh and cached native projections preserve pinned hourly and quota slices`() async throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.writePiHistory()

        let baseline = try await fixture.load(includePi: false)
        #expect(baseline.accounting == .nativeOnly)
        #expect(baseline.snapshot.historyCoverageIsEstablished)
        #expect(baseline.snapshot.last30DaysTokens == 140)
        #expect(baseline.snapshot.hourly.map(\.hour) == fixture.hours)
        #expect(baseline.snapshot.hourly.map(\.totalTokens) == [100, 40])
        #expect(baseline.snapshot.quotaSlices.map(\.timestamp) == fixture.events)
        #expect(baseline.snapshot.quotaSlices.map(\.totalTokens) == [100, 40])

        let fresh = try await fixture.load(includePi: true)
        #expect(fresh.snapshot.historyCoverageIsEstablished)
        #expect(fresh.snapshot.last30DaysTokens == 195)
        #expect(fresh.snapshot.hourly == baseline.snapshot.hourly)
        #expect(fresh.snapshot.quotaSlices == baseline.snapshot.quotaSlices)
        guard case let .includesPi(freshScope, freshNative) = fresh.accounting else {
            Issue.record("Expected fresh inclusive Pi accounting with a native projection")
            return
        }
        #expect(!freshScope.isEmpty)
        #expect(freshNative.daily == baseline.snapshot.daily)
        #expect(freshNative.hourly == baseline.snapshot.hourly)
        #expect(freshNative.quotaSlices == baseline.snapshot.quotaSlices)
        #expect(freshNative.last30DaysTokens == 140)
        #expect(freshNative.historyCoverageIsEstablished)
        try fixture.expectNativeQuotaWindow(freshNative)

        let cachedValue = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.now.addingTimeInterval(60),
            historyDays: 1,
            includePiSessions: true,
            scannerOptions: fixture.options,
            environment: fixture.environment,
            piScannerOptions: fixture.piOptions)
        let cached = try #require(cachedValue)
        #expect(cached.snapshot.historyCoverageIsEstablished)
        #expect(cached.snapshot.last30DaysTokens == 195)
        #expect(cached.snapshot.hourly == baseline.snapshot.hourly)
        #expect(cached.snapshot.quotaSlices == baseline.snapshot.quotaSlices)
        guard case let .includesPi(cachedScope, cachedNative) = cached.accounting else {
            Issue.record("Expected cached inclusive Pi accounting with a native projection")
            return
        }
        #expect(cachedScope == freshScope)
        #expect(cachedNative.daily == freshNative.daily)
        #expect(cachedNative.hourly == freshNative.hourly)
        #expect(cachedNative.quotaSlices == freshNative.quotaSlices)
        #expect(cachedNative.last30DaysTokens == 140)
        #expect(cachedNative.historyCoverageIsEstablished)
        try fixture.expectNativeQuotaWindow(cachedNative)
    }

    @Test
    func `missing Pi cache leaves native hydration incomplete without claiming a refresh TTL`() async throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        // A transcript exists, but a cached-only read cannot claim it was inspected.
        try fixture.writePiHistory()
        let baseline = try await fixture.load(includePi: false)
        let piCacheURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: fixture.env.cacheRoot)
        #expect(!FileManager.default.fileExists(atPath: piCacheURL.path))

        let controlValue = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.now.addingTimeInterval(60),
            historyDays: 1,
            includePiSessions: false,
            scannerOptions: fixture.options,
            environment: fixture.environment,
            piScannerOptions: fixture.piOptions)
        let control = try #require(controlValue)
        #expect(control.accounting == .nativeOnly)
        #expect(control.snapshot.historyCoverageIsEstablished)
        #expect(control.lastRefreshAt == fixture.now)

        let partialValue = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.now.addingTimeInterval(60),
            historyDays: 1,
            includePiSessions: true,
            scannerOptions: fixture.options,
            environment: fixture.environment,
            piScannerOptions: fixture.piOptions)
        let partial = try #require(partialValue)
        #expect(partial.accounting == .nativeOnly)
        #expect(partial.snapshot.last30DaysTokens == 140)
        #expect(partial.snapshot.daily == baseline.snapshot.daily)
        #expect(partial.snapshot.hourly == baseline.snapshot.hourly)
        #expect(partial.snapshot.quotaSlices == baseline.snapshot.quotaSlices)
        #expect(!partial.snapshot.historyCoverageIsEstablished)
        #expect(partial.lastRefreshAt == nil)
        #expect(partial.staleSnapshotUpdatedAt == nil)
        #expect(partial.snapshot.updatedAt == control.snapshot.updatedAt)
        #expect(!FileManager.default.fileExists(atPath: piCacheURL.path))

        let strict = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.now.addingTimeInterval(60),
            historyDays: 1,
            includePiSessions: true,
            requireCompleteHistory: true,
            scannerOptions: fixture.options,
            environment: fixture.environment,
            piScannerOptions: fixture.piOptions)
        #expect(strict == nil)
        #expect(!FileManager.default.fileExists(atPath: piCacheURL.path))

        let refreshed = try await fixture.load(includePi: true)
        #expect(refreshed.snapshot.historyCoverageIsEstablished)
        #expect(refreshed.snapshot.last30DaysTokens == 195)
        guard case .includesPi = refreshed.accounting else {
            Issue.record("Expected a fresh scan to establish Pi ownership after missing-cache hydration")
            return
        }
    }

    @Test
    func `cached Pi history without native data retains Pi-only accounting`() async throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        try fixture.writePiHistory()
        let scanned = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now,
            options: fixture.piOptions,
            checkCancellation: nil)
        #expect(scanned.isComplete)
        let cachedValue = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.now,
            historyDays: 1,
            includePiSessions: true,
            scannerOptions: fixture.options,
            environment: fixture.environment,
            piScannerOptions: fixture.piOptions)
        let cached = try #require(cachedValue)
        #expect(cached.snapshot.last30DaysTokens == 55)
        #expect(!cached.snapshot.historyCoverageIsEstablished)
        #expect(cached.lastRefreshAt == nil)
        guard case let .piOnly(scope) = cached.accounting else {
            Issue.record("Pi-only hydration must not claim native source ownership")
            return
        }
        #expect(scope == scanned.scopeFingerprint)
    }

    @Test
    func `invalid dated usage outside the scan window does not poison current Pi history`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let old = try #require(fixture.calendar.date(byAdding: .day, value: -90, to: fixture.events[0]))
        _ = try fixture.env.writePiSessionFile(
            relativePath: "long-lived.jsonl",
            contents: fixture.env.jsonl([
                fixture.piRow(at: old, input: true),
                fixture.piRow(at: fixture.events[0], input: 10),
            ]))
        let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .pi,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now,
            options: fixture.piOptions,
            checkCancellation: nil)
        #expect(result.isComplete)
        #expect(result.report.summary?.totalTokens == 10)
        #expect(result.report.data.map(\.date) == ["2026-04-08"])
        #expect(result.lastScanAt == fixture.now)
    }

    private struct Fixture {
        let env: CostUsageTestEnvironment
        let calendar: Calendar
        let now: Date
        let events: [Date]
        let hours: [Date]
        let resetStart: Date
        let options: CostUsageScanner.Options
        let piOptions: PiSessionCostScanner.Options
        let environment: [String: String]

        init() throws {
            let env = try CostUsageTestEnvironment()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kathmandu"))
            let first = try #require(calendar.date(from: DateComponents(
                year: 2026, month: 4, day: 8, hour: 0, minute: 20)))
            let second = first.addingTimeInterval(3600)
            let now = try #require(calendar.date(from: DateComponents(
                year: 2026, month: 4, day: 8, hour: 12, minute: 30)))
            let resetStart = try #require(calendar.date(from: DateComponents(
                year: 2026, month: 4, day: 8, hour: 0, minute: 45)))
            let hours = try [first, second].map { try #require(calendar.dateInterval(of: .hour, for: $0)?.start) }
            let environment = ["HOME": env.root.path]
            let omp = env.root.appendingPathComponent("empty-omp", isDirectory: true)
            try FileManager.default.createDirectory(at: omp, withIntermediateDirectories: true)
            var options = CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                cacheRoot: env.cacheRoot,
                codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
                calendar: calendar)
            options.refreshMinIntervalSeconds = 0
            let piOptions = PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                ompSessionsRoot: omp,
                cacheRoot: env.cacheRoot,
                calendar: calendar,
                refreshMinIntervalSeconds: 0,
                environment: environment)
            self.env = env
            self.calendar = calendar
            self.now = now
            self.events = [first, second]
            self.hours = hours
            self.resetStart = resetStart
            self.options = options
            self.piOptions = piOptions
            self.environment = environment

            var rows: [[String: Any]] = [[
                "type": "session_meta",
                "timestamp": env.isoString(for: first.addingTimeInterval(-2)),
                "payload": ["id": "synthetic-native-projection", "cwd": env.root.path],
            ]]
            for (index, event) in [first, second].enumerated() {
                rows.append([
                    "type": "turn_context",
                    "timestamp": env.isoString(for: event.addingTimeInterval(-1)),
                    "payload": ["model": "gpt-5.4", "turn_id": "synthetic-turn-\(index)"],
                ])
                rows.append([
                    "type": "event_msg",
                    "timestamp": env.isoString(for: event),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": index == 0 ? 100 : 40,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ])
            }
            _ = try env.writeCodexSessionFile(
                day: first, filename: "native-projection.jsonl", contents: env.jsonl(rows))
        }

        func load(includePi: Bool) async throws -> CostUsageTokenResult {
            try await CostUsageFetcher.loadTokenResult(
                provider: .codex,
                environment: self.environment,
                now: self.now,
                historyDays: 1,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: includePi,
                scannerOptions: self.options,
                piScannerOptions: self.piOptions)
        }

        func writePiHistory() throws {
            var row = self.piRow(at: self.events[0], input: 50)
            var message = try #require(row["message"] as? [String: Any])
            message["usage"] = ["input": 50, "output": 5, "totalTokens": 55]
            row["message"] = message
            _ = try self.env.writePiSessionFile(
                relativePath: "pi-projection.jsonl", contents: self.env.jsonl([row]))
        }

        func piRow(at date: Date, input: Any) -> [String: Any] {
            [
                "type": "message",
                "timestamp": self.env.isoString(for: date),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "usage": ["input": input, "output": 0],
                ],
            ]
        }

        func expectNativeQuotaWindow(_ snapshot: CostUsageTokenSnapshot) throws {
            let resetAt = self.resetStart.addingTimeInterval(7 * 24 * 60 * 60)
            let week = try #require(snapshot.quotaWeekSummaries(
                resetAt: resetAt,
                observedResetInstants: [self.resetStart],
                weekCount: 1,
                now: self.now,
                calendar: self.calendar).first)
            #expect(week.start == self.resetStart)
            #expect(week.totalTokens == 40)
            #expect(week.tokensAreComplete)
            #expect(week.costIsComplete)
        }
    }
}
