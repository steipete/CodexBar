import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ElevenLabsPluginTests {
    #if canImport(JavaScriptCore)
    private static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif
    private static let fixture = #"""
    {
      "tier": "creator",
      "character_count": 25000,
      "character_limit": 100000,
      "voice_slots_used": 2,
      "voice_limit": 10,
      "professional_voice_slots_used": 1,
      "professional_voice_limit": 2,
      "current_overage": {"amount": "0", "currency": "usd"},
      "status": "active",
      "next_character_count_reset_unix": 1738356858
    }
    """#

    @Test(arguments: Self.engines)
    func `subscription fixture matches native golden`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(usage.primary == RateWindow(
            usedPercent: 25, windowMinutes: nil,
            resetsAt: Date(timeIntervalSince1970: 1_738_356_858),
            resetDescription: "25,000 / 100,000 credits"))
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.loginMethod(for: .elevenlabs) == "Creator")
        #expect(usage.extraRateWindows == [
            NamedRateWindow(id: "voice-slots", title: "Voice slots", window: RateWindow(
                usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: "2 / 10")),
            NamedRateWindow(id: "professional-voices", title: "Professional voices", window: RateWindow(
                usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: "1 / 2")),
        ])
        #expect(usage.identity?.providerID == .elevenlabs)
        #expect(usage.providerCost == nil)
    }

    @Test(arguments: Self.engines)
    func `quota edge cases preserve native and Linux goldens`(engine: ProviderPluginEngineKind) async throws {
        for (count, limit, used, expected) in [
            (25000, 100_000, 2, 25.0),
            (150_000, 100_000, 12, 100),
            (-1, 100_000, -1, 0),
            (10, 0, 0, 0),
            (10, -1, 0, 0),
        ] {
            let body = """
            {"character_count":\(count),"character_limit":\(limit),"voice_slots_used":\(used),"voice_limit":10}
            """
            let usage = try await Self.fetch(body, engine: engine)
            #expect(usage.primary?.usedPercent == expected)
            #expect(usage.extraRateWindows?.first?.window.usedPercent == min(100, max(0, Double(used) * 10)))
            #expect(usage.primary?.resetsAt == nil)
            #expect(usage.loginMethod(for: .elevenlabs) == nil)
        }
        let usage = try await Self.fetch(
            #"{"character_count":0,"character_limit":0,"voice_slots_used":2,"voice_limit":0,"professional_voice_limit":2}"#,
            engine: engine)
        #expect(usage.extraRateWindows == nil)
    }

    @Test(arguments: Self.engines)
    func `plan labels preserve title casing and status fallback`(engine: ProviderPluginEngineKind) async throws {
        for (tier, status, expected) in [
            ("creator", "active", "Creator"), (" growing_business ", "past_due", "Growing Business · past_due"),
            ("PRO", "ACTIVE", "Pro"), ("", "trialing", "trialing"), ("starter", "", "Starter"),
        ] {
            let body = """
            {"character_count":0,"character_limit":1,"tier":"\(tier)","status":"\(status)"}
            """
            #expect(try await Self.fetch(body, engine: engine).loginMethod(for: .elevenlabs) == expected)
        }
    }

    @Test(arguments: Self.engines)
    func `request uses xi header canonical endpoint and deadline`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(engine: engine, transport: ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user/subscription")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return try Self.response(request, body: Self.fixture)
        })
        _ = try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://api.elevenlabs.io/v1/user/subscription"],
            secrets: ["ELEVENLABS_API_KEY": "xi-test"])
    }

    @Test(arguments: [
        (401, #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, "rejected"),
        (401, #"{"detail":{"status":"missing_permissions","message":"Missing user_read permission"}}"#, "permission"),
        (401, #"{"detail":{"status":"authentication_failed"}}"#, "authentication"),
        (403, #"{"detail":{"status":"forbidden"}}"#, "access"),
        (401, #"{"detail":{"code":"invalid_api_key"}}"#, "rejected"),
        (401, #"{"detail":{"code":"unauthorized","status":"invalid_api_key"}}"#, "rejected"),
        (401, #"{"detail":{"code":" INVALID_API_KEY ","status":"missing_permissions"}}"#, "rejected"),
        (401, #"{"detail":{"code":" ","status":"invalid_api_key"}}"#, "rejected"),
        (403, #"{"detail":{"code":"insufficient_permissions"}}"#, "permission"),
        (403, #"{"detail":{"status":"missing_permissions"}}"#, "permission"),
        (401, #"{"detail":{"code":"unknown","message":"sensitive-response-marker"}}"#, "authentication"),
        (403, #"{"detail":{"code":"unknown","message":"sensitive-response-marker"}}"#, "access"),
        (401, #"{"detail":{}}"#, "authentication"),
        (401, #"{"detail":"sensitive-response-marker"}"#, "authentication"),
        (401, #"{"detail":{"code":123}}"#, "authentication"),
        (401, #"{"detail":{"code":123,"status":"invalid_api_key"}}"#, "authentication"),
        (403, #"{"detail":null}"#, "access"),
        (401, "", "authentication"), (403, "not JSON", "access"),
    ], Self.engines)
    func `current and legacy authentication fixtures preserve safe diagnostics`(
        argument: (Int, String, String), engine: ProviderPluginEngineKind) async throws
    {
        let (status, body, expected) = argument
        let messages = [
            "rejected": "ElevenLabs rejected the selected API key. Check that it is valid and has not been revoked.",
            "permission": "ElevenLabs API key is missing the user_read permission required to fetch subscription usage.",
            "authentication": "ElevenLabs could not authenticate the selected API key. Check the key and its permissions.",
            "access": "ElevenLabs denied access for the selected API key. Check its endpoint permissions and IP allowlist.",
        ]
        let kind: ProviderFetchClassifiedError.Kind = ["permission", "access"].contains(expected)
            ? .permissionDenied : .authenticationExpired
        try await Self.expectFailure(kind, message: #require(messages[expected])) {
            try await Self.fetch(body, engine: engine, status: status)
        }
    }

    @Test(arguments: [
        (429, ProviderFetchClassifiedError.Kind.rateLimited),
        (500, .providerUnavailable),
        (404, .apiFailure),
    ], Self.engines)
    func `non success responses omit bodies`(
        argument: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(argument.1, message: "ElevenLabs API error: HTTP \(argument.0)") {
            try await Self.fetch(#"{"detail":"sensitive-response-marker"}"#, engine: engine, status: argument.0)
        }
    }

    @Test(arguments: Self.engines)
    func `malformed subscription fields remain parse failures`(engine: ProviderPluginEngineKind) async {
        for body in [
            "not JSON",
            "[]",
            "null",
            "{}",
            #"{"character_count":"1","character_limit":10}"#,
            #"{"character_count":1.5,"character_limit":10}"#,
            #"{"character_count":1,"character_limit":10,"voice_slots_used":"2"}"#,
            #"{"character_count":1,"character_limit":10,"tier":42}"#,
            #"{"character_count":1,"character_limit":10,"current_overage":{"amount":2}}"#,
        ] {
            await Self.expectFailure(
                .parseFailure,
                message: "Failed to parse ElevenLabs response: invalid subscription response")
            {
                try await Self.fetch(body, engine: engine)
            }
        }
    }

    private static func fetch(
        _ body: String, engine: ProviderPluginEngineKind, status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try Self.runtime(engine: engine, transport: ProviderHTTPTransportHandler { request in
            try Self.response(request, body: body, status: status)
        })
        return try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://api.elevenlabs.io/v1/user/subscription"],
            secrets: ["ELEVENLABS_API_KEY": "xi-test"])
    }

    private static func runtime(
        engine: ProviderPluginEngineKind, transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let url = try #require(bundle.url(forResource: "elevenlabs", withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8),
            transport: transport,
            engine: engine)
    }

    private static func response(_ request: URLRequest, body: String, status: Int = 200) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind, message: String,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(error.message == message)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
