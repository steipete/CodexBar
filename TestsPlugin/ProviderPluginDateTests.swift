import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProviderPluginDateTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `daily resets keep wall clock times across offset changes`(engine: ProviderPluginEngineKind) async throws {
        for fixture in Self.resetFixtures {
            let runtime = try Self.runtime(zone: fixture.zone, hour: String(fixture.hour), engine: engine)
            let expected = try Self.date(fixture.expected)
            let snapshot = try await runtime.fetchUsage(
                now: Self.date(fixture.now),
                sourceMode: .api,
                cookieSource: .off)
            #expect(
                snapshot.primary?.resetsAt == expected,
                "\(fixture.zone), hour \(fixture.hour), now \(fixture.now)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `daily resets are strictly after the fetch clock`(engine: ProviderPluginEngineKind) async throws {
        let boundary = try Self.date("2026-03-08T09:00:00Z")
        for delta in [-0.001, 0, 0.001] {
            let runtime = try Self.runtime(zone: "UTC", hour: "9", engine: engine)
            let snapshot = try await runtime.fetchUsage(
                now: boundary.addingTimeInterval(delta),
                sourceMode: .api,
                cookieSource: .off)
            let expected = try Self.date(delta < 0 ? "2026-03-08T09:00:00Z" : "2026-03-09T09:00:00Z")
            #expect(snapshot.primary?.resetsAt == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `daily resets reject invalid hours and time zones`(engine: ProviderPluginEngineKind) async throws {
        let invalid = [
            ("UTC", "-1"), ("UTC", "24"), ("UTC", "1.5"), ("UTC", "NaN"),
            ("UTC", "Infinity"), ("UTC", "-Infinity"), ("UTC", "Number.MAX_VALUE"),
            ("", "9"), ("Not/A_Real_Zone", "9"),
        ]
        for (zone, hour) in invalid {
            let runtime = try Self.runtime(zone: zone, hour: hour, engine: engine)
            await #expect(throws: ProviderPluginError.self) {
                try await runtime.fetchUsage(
                    now: Self.date("2026-03-08T06:00:00Z"),
                    sourceMode: .api,
                    cookieSource: .off)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `daily resets accept negative zero as midnight`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(zone: "UTC", hour: "-0", engine: engine)
        let snapshot = try await runtime.fetchUsage(
            now: Self.date("2026-03-08T06:00:00Z"),
            sourceMode: .api,
            cookieSource: .off)
        let expected = try Self.date("2026-03-09T00:00:00Z")
        #expect(snapshot.primary?.resetsAt == expected)
    }

    private static func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private static func runtime(
        zone: String,
        hour: String,
        engine: ProviderPluginEngineKind) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: "date-fixture",
              name: "Date fixture",
              endpoints: ["https://date.invalid"],
              settings: [],
              async fetchUsage(ctx) {
                return { primary: {
                  usedPercent: 0,
                  resetsAt: ctx.date.nextDailyReset("\(zone)", \(hour))
                } };
              }
            });
            """,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Date-only plugin unexpectedly requested HTTP")
                throw URLError(.unsupportedURL)
            },
            enforcesUserResponsePolicy: true,
            allowsDynamicID: true,
            engine: engine)
    }

    private static let resetFixtures: [(zone: String, now: String, hour: Int, expected: String)] = [
        ("UTC", "2026-03-08T06:00:00Z", 9, "2026-03-08T09:00:00Z"),
        ("UTC", "2026-03-08T09:00:00Z", 9, "2026-03-09T09:00:00Z"),
        ("America/New_York", "2026-03-07T06:00:00Z", 9, "2026-03-07T14:00:00Z"),
        ("America/New_York", "2026-03-08T06:00:00Z", 9, "2026-03-08T13:00:00Z"),
        ("America/New_York", "2026-11-01T05:00:00Z", 9, "2026-11-01T14:00:00Z"),
        ("Australia/Sydney", "2026-10-03T15:00:00Z", 9, "2026-10-03T22:00:00Z"),
        ("Australia/Sydney", "2026-04-04T14:00:00Z", 9, "2026-04-04T23:00:00Z"),
        ("Australia/Lord_Howe", "2026-10-03T14:30:00Z", 9, "2026-10-03T22:00:00Z"),
        ("Australia/Lord_Howe", "2026-04-04T14:00:00Z", 9, "2026-04-04T22:30:00Z"),
        ("America/New_York", "2026-03-08T22:00:00Z", 9, "2026-03-09T13:00:00Z"),
        ("America/New_York", "2026-11-01T22:00:00Z", 9, "2026-11-02T14:00:00Z"),
        ("America/New_York", "2026-03-08T13:30:00Z", 9, "2026-03-09T13:00:00Z"),
        ("America/New_York", "2026-11-01T13:30:00Z", 9, "2026-11-01T14:00:00Z"),
        ("America/New_York", "2026-03-08T06:00:00Z", 2, "2026-03-08T07:00:00Z"),
        ("America/New_York", "2026-03-08T07:00:00Z", 2, "2026-03-09T06:00:00Z"),
        ("America/New_York", "2026-03-08T07:30:00Z", 2, "2026-03-09T06:00:00Z"),
        ("America/New_York", "2026-11-01T04:30:00Z", 1, "2026-11-01T05:00:00Z"),
        ("America/New_York", "2026-11-01T05:00:00Z", 1, "2026-11-02T06:00:00Z"),
        ("America/New_York", "2026-11-01T05:30:00Z", 1, "2026-11-02T06:00:00Z"),
        ("America/New_York", "2026-11-01T06:00:00Z", 1, "2026-11-02T06:00:00Z"),
        ("Australia/Lord_Howe", "2026-10-03T14:30:00Z", 2, "2026-10-03T15:30:00Z"),
        ("America/Sao_Paulo", "2018-11-04T02:30:00Z", 0, "2018-11-04T03:00:00Z"),
        ("Pacific/Apia", "2011-12-30T09:30:00Z", 0, "2011-12-30T10:00:00Z"),
        ("America/Havana", "2025-11-02T03:30:00Z", 0, "2025-11-02T04:00:00Z"),
        ("America/Havana", "2025-11-02T04:30:00Z", 0, "2025-11-03T05:00:00Z"),
    ]
}
