import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MiMoTokenPlanPluginTests {
    /// Documented at mimo.mi.com/docs/en-US/api/asset/credits-get; dates are UTC.
    private static let fixture = #"""
    {"object":"token_plan","plan_code":"lite",
     "period":{"start_at":"2026-11-11 21:05:27","end_at":"2026-12-11 23:59:59"},
     "quota":{"total_credits":4100000000,"used_credits":1400000000,"remaining_credits":2700000000},
     "auto_renew":true,"claw_enabled":false}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Token Plan key reads quota at the selected regional origin without browser access`(
        engine: ProviderPluginEngineKind) async throws
    {
        for region in ["cn", "sgp"] {
            let snapshot = try await Self.fetch(engine, region: region)
            #expect(abs((snapshot.primary?.usedPercent ?? -1) - 140.0 / 4.1) < 0.000001)
            #expect(snapshot.primary?.quotaLimit == 4_100_000_000)
            #expect(snapshot.primary?.quotaUnit == "credits")
            #expect(snapshot.primary?.resetsAt == ISO8601DateParser.parse("2026-12-11T23:59:59Z"))
            #expect(snapshot.primary?.windowMinutes == nil) // No rounding of a partial minute.
            #expect(snapshot.identity?.loginMethod == "lite")
            #expect(snapshot.providerCost == nil)
            #expect(snapshot.details.isEmpty)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid Token Plan counters and dates never become zero usage`(engine: ProviderPluginEngineKind) async {
        for body in [
            "{}", "[]", "not-json",
            Self.fixture.replacingOccurrences(of: "4100000000", with: "-1"),
            Self.fixture.replacingOccurrences(of: "1400000000", with: "true"),
            Self.fixture.replacingOccurrences(of: "2700000000", with: "0"),
            Self.fixture.replacingOccurrences(of: "2026-12-11", with: "2026-02-30"),
        ] {
            await #expect(throws: (any Error).self) { try await Self.fetch(engine, body: body) }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported exhausted quota remains measured and API errors fail the selected source`(
        engine: ProviderPluginEngineKind) async throws
    {
        let exhausted = Self.fixture
            .replacingOccurrences(of: "1400000000", with: "4100000000")
            .replacingOccurrences(of: "2700000000", with: "0")
        #expect(try await Self.fetch(engine, body: exhausted).primary?.usedPercent == 100)
        for status in [401, 403, 429, 500] {
            let kind: ProviderFetchClassifiedError.Kind = switch status {
            case 401: .authenticationExpired
            case 403: .permissionDenied
            case 429: .rateLimited
            default: .providerUnavailable
            }
            await #expect {
                try await Self.fetch(engine, status: status)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == kind
            }
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        region: String = "sgp",
        body: String = Self.fixture,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "mimo", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?
                    .absoluteString == "https://token-plan-\(region).xiaomimimo.com/v1/platform/token_plan")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tp-fixture")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let url = try #require(request.url)
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
            })
        #expect(!runtime.manifest.capabilities.contains(.browserCookies))
        return try await runtime.fetchUsage(settings: ["REGION": region], secrets: ["MIMO_API_KEY": "tp-fixture"])
    }
}
