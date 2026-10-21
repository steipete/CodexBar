import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SofyaPluginTests {
    static let fixture = """
    {"credits": 1034, "plan_credits": 997, "purchased_credits": 37, "is_free_tier": true,
     "credits_reset_at": "2026-11-04T12:00:00Z", "total_requests": 3,
     "api_key": "private-response-key", "email": "private-response@example.test",
     "github_username": "private-response-user", "last_login_method": "private-response-login"}
    """

    @Test(arguments: BundledPluginTestSupport.engines)
    func `free tier preserves separate balances and supplied reset without a quota bar`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.first?.rows.map(\.label) == [
            "Available credits", "Plan credits", "Purchased credits", "Monthly reset",
        ])
        #expect(snapshot.details.first?.rows.map(\.value) == ["1,034", "997", "37", "2026-11-04 12:00:00 UTC"])
        #expect(snapshot.identity?.providerID == .sofya)
        #expect(snapshot.identity?.loginMethod == "Free tier")
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.identity?.accountID == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(!String(describing: snapshot).contains("private-response"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pay as you go keeps zero credits and does not inherit free eligibility or reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            #"{"credits":0,"plan_credits":0,"purchased_credits":0,"is_free_tier":false}"#,
            engine: engine)
        #expect(snapshot.identity?.loginMethod == "Pay as you go")
        #expect(snapshot.details.first?.rows.map(\.value) == ["0", "0", "0"])
        #expect(snapshot.primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing account fields stay unavailable without inferred balance or eligibility`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            #"{"purchased_credits":37,"plan_credits":null,"credits_reset_at":null}"#,
            engine: engine)
        #expect(snapshot.details.first?.rows.map(\.label) == ["Purchased credits"])
        #expect(snapshot.details.first?.rows.map(\.value) == ["37"])
        #expect(snapshot.identity?.loginMethod == "API")
        #expect(snapshot.primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `free tier without a reset does not invent one and offset resets normalize to UTC`(
        engine: ProviderPluginEngineKind) async throws
    {
        let withoutReset = try await Self.fetch(
            #"{"credits":37.25,"is_free_tier":true,"credits_reset_at":null}"#,
            engine: engine)
        #expect(withoutReset.details.first?.rows.map(\.value) == ["37.25"])
        let offsetReset = try await Self.fetch(
            Self.fixture.replacingOccurrences(of: "2026-11-04T12:00:00Z", with: "2026-11-04T14:00:00.125+02:00"),
            engine: engine)
        #expect(offsetReset.details.first?.rows.last?.value == "2026-11-04 12:00:00.125 UTC")
    }

    @Test(arguments: ["credits", "plan_credits", "purchased_credits"], BundledPluginTestSupport.engines)
    func `malformed supplied balances fail instead of becoming zero`(
        key: String, engine: ProviderPluginEngineKind) async throws
    {
        for value in ["-1", "true", "[]", "{}", #""37""#, "1e999"] {
            let body = "{\"\(key)\":\(value),\"is_free_tier\":true}"
            await #expect(throws: ProviderFetchClassifiedError.self) {
                try await Self.fetch(body, engine: engine)
            }
        }
    }

    @Test(arguments: [
        "not-json", "null", "[]", "{}", #"{"api_key":"private-response-key"}"#,
        #"{"credits":1,"is_free_tier":"true"}"#,
        #"{"credits":1,"credits_reset_at":123}"#,
        #"{"credits":1,"credits_reset_at":"2026-11-04"}"#,
        #"{"credits":1,"credits_reset_at":"2026-99-99T12:00:00Z"}"#,
        #"{"credits":1,"credits_reset_at":"2026-02-31T12:00:00Z"}"#,
    ], BundledPluginTestSupport.engines)
    func `invalid account shapes and dates produce safe parse failures`(
        body: String, engine: ProviderPluginEngineKind) async throws
    {
        do {
            _ = try await Self.fetch(body, engine: engine)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(!error.message.contains("private-response"))
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
        (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
    ], BundledPluginTestSupport.engines)
    func `HTTP failures are classified without returned account secrets`(
        argument: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async throws
    {
        do {
            _ = try await Self.fetch("private-response-key", engine: engine, status: argument.0)
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == argument.1)
            #expect(!error.message.contains("private-response"))
        }
    }

    static func fetch(
        _ body: String = Self.fixture,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "sofya",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://sofya.co/v1/auth/me")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.timeoutInterval == 15)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["SOFYA_API_KEY": "fixture-key"])
    }
}
