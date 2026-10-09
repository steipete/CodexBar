import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SailResearchPluginTests {
    /// Documented usage.summary shape with synthetic money and fixed query boundaries.
    static var fixture: [String: Any] {
        [
            "object": "usage.summary", "available": true, "has_metronome_customer": true,
            "empty": false, "balance_unavailable": false, "balance": 12345.67, "period_spend": 1234,
            "effective_range": "30d", "plan_limited": false, "days_remaining": 21,
            "rolling_window": ["start": "2026-09-01T12:37:00Z", "end": "2026-10-01T12:37:00Z"],
            "billing_window": ["start": "2026-09-01T12:00:00Z", "end": "2026-10-01T13:00:00Z"],
        ]
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `fractional cents become organization USD without inferred quotas or resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.first?.title == "Organization billing")
        #expect(snapshot.details.first?.rows.map(\.label) == ["Credit balance", "Last 30 days spend"])
        #expect(snapshot.details.first?.rows.map(\.value) == ["$123.46", "$12.34"])
        #expect(snapshot.identity?.providerID == .sailresearch)
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `plan limited history uses the effective range`(engine: ProviderPluginEngineKind) async throws {
        var data = Self.fixture
        data["effective_range"] = "7d"
        data["plan_limited"] = true
        let snapshot = try await Self.fetch(data, engine: engine)
        #expect(snapshot.details.first?.rows.last?.label == "Last 7 days spend")
    }

    @Test(arguments: [0.0, -125.0], BundledPluginTestSupport.engines)
    func `zero and negative balances remain authoritative`(
        balance: Double, engine: ProviderPluginEngineKind) async throws
    {
        var data = Self.fixture
        data["balance"] = balance
        data["period_spend"] = 0
        data["empty"] = true
        let snapshot = try await Self.fetch(data, engine: engine)
        #expect(snapshot.details.first?.rows.first?.value == (balance == 0 ? "$0.00" : "-$1.25"))
        #expect(snapshot.details.first?.rows.last?.value == "$0.00")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable balance preserves spend without displaying a false zero`(
        engine: ProviderPluginEngineKind) async throws
    {
        var data = Self.fixture
        data["balance_unavailable"] = true
        data.removeValue(forKey: "balance")
        let snapshot = try await Self.fetch(data, engine: engine)
        #expect(snapshot.details.first?.rows.map(\.value) == ["Unavailable", "$12.34"])
    }

    @Test(arguments: [
        ("available", ProviderFetchClassifiedError.Kind.providerUnavailable),
        ("has_metronome_customer", .apiFailure),
    ], BundledPluginTestSupport.engines)
    func `missing billing data never becomes zero credits`(
        argument: (String, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async throws
    {
        var data = Self.fixture
        data[argument.0] = false
        do {
            _ = try await Self.fetch(data, engine: engine)
            Issue.record("Expected unavailable billing failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == argument.1)
        }
    }

    @Test(arguments: ["balance", "period_spend"], BundledPluginTestSupport.engines)
    func `malformed monetary values fail closed`(key: String, engine: ProviderPluginEngineKind) async throws {
        let values: [Any] = ["100", true, NSNull(), ["value": 100]]
        for value in values {
            var data = Self.fixture
            data[key] = value
            await #expect(throws: ProviderFetchClassifiedError.self) { try await Self.fetch(data, engine: engine) }
        }
    }

    @Test(arguments: [
        "object", "available", "has_metronome_customer", "balance_unavailable", "balance", "period_spend",
        "effective_range",
    ], BundledPluginTestSupport.engines)
    func `missing required billing fields fail closed`(key: String, engine: ProviderPluginEngineKind) async throws {
        var data = Self.fixture
        data.removeValue(forKey: key)
        await #expect(throws: ProviderFetchClassifiedError.self) { try await Self.fetch(data, engine: engine) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `negative spend and unknown ranges fail closed`(engine: ProviderPluginEngineKind) async throws {
        var data = Self.fixture
        data["period_spend"] = -1
        await #expect(throws: ProviderFetchClassifiedError.self) { try await Self.fetch(data, engine: engine) }
        data = Self.fixture
        data["effective_range"] = "toString"
        await #expect(throws: ProviderFetchClassifiedError.self) { try await Self.fetch(data, engine: engine) }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (402, .apiFailure), (403, .permissionDenied),
        (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
    ], BundledPluginTestSupport.engines)
    func `HTTP failures are classified without exposing bodies`(
        argument: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async throws
    {
        do {
            _ = try await Self.fetch(engine: engine, status: argument.0)
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == argument.1)
            #expect(!error.message.contains("private-response"))
        }
    }

    @Test(arguments: ["not-json", "{}", "null"], BundledPluginTestSupport.engines)
    func `malformed responses are parse failures`(body: String, engine: ProviderPluginEngineKind) async throws {
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.fetch(engine: engine, body: body)
        }
    }

    static func fetch(
        _ data: [String: Any] = Self.fixture,
        engine: ProviderPluginEngineKind,
        status: Int = 200,
        body: String? = nil) async throws -> UsageSnapshot
    {
        let payload = try JSONSerialization.data(withJSONObject: data)
        let runtime = try BundledPluginTestSupport.runtime(
            "sailresearch",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.sailresearch.com/v2/usage/summary?range=30d")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.timeoutInterval == 15)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (status == 200 ? body.map { Data($0.utf8) } ?? payload : Data("private-response".utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["SAIL_API_KEY": "fixture-key"])
    }
}
