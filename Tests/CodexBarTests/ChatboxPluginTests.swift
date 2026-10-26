import Foundation
import Testing
@testable import CodexBarCore

struct ChatboxPluginTests {
    static let fixture = #"""
    {"data":{"key":"private-response-key","name":"Chatbox AI Pro","plan":"pro","status":"active",
    "unified_token_usage":300,"unified_token_limit":1500,
    "unified_token_usage_details":[{"type":"plan","token_usage":200,"token_limit":1000},
    {"type":"invitation_reward","token_usage":100,"token_limit":500}],
    "aggregated_reward_details":{"token_usage":100,"token_limit":500},
    "expansion_pack_usage":50,"expansion_pack_limit":400,"image_used_count":3,"image_total_quota":20,
    "token_refreshed_time":"2026-10-01T00:00:00Z","token_next_refresh_time":"2026-11-01T00:00:00Z",
    "token_expire_time":"2027-01-01T00:00:00Z"}}
    """#
    private static let now = Date(timeIntervalSince1970: 1_792_454_400) // 2026-10-20 UTC

    @Test(arguments: BundledPluginTestSupport.engines)
    func `plugin uses translated recovery guidance supplied by the descriptor`(
        engine: ProviderPluginEngineKind) async throws
    {
        let key = "Chatbox AI denied access. Check your license."
        let translated = "Chatbox AI a refusé l’accès. Vérifiez votre licence."
        let messages = try #require(String(data: JSONEncoder().encode([key: translated]), encoding: .utf8))
        let runtime = try BundledPluginTestSupport.runtime(
            "chatbox", engine: engine, transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: "private-response-key", status: 403)
            })
        do {
            _ = try await runtime.fetchUsage(
                settings: ["MESSAGES": messages], secrets: ["CHATBOX_LICENSE_KEY": "fixture-key"], now: Self.now)
            Issue.record("Expected permission denial")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .permissionDenied)
            #expect(error.message == translated + " (HTTP 403)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `plan rewards expansion and images preserve separate quota pools`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == Self.date("2026-11-01T00:00:00Z"))
        #expect(usage.secondary?.usedPercent == 12.5)
        #expect(usage.secondary?.resetsAt == nil)
        #expect(usage.identity?.loginMethod == "Chatbox AI Pro")
        #expect(usage.identity?.accountEmail == nil)
        #expect(usage.identity?.accountID == nil)
        #expect(usage.details.first?.rows.prefix(4).map(\.value) == [
            "800 / 1,000", "400 / 500", "350 / 400",
            "17 / 20",
        ])
        #expect(usage.details.first?.title == "Remaining")
        #expect(usage.details.flatMap(\.rows).allSatisfy { $0.progress == nil })
        #expect(!usage.details.flatMap(\.rows).contains {
            ["Plan expiry", "Next plan reset"].contains($0.label)
        })
        #expect(usage.subscriptionExpiresAt == Self.date("2027-01-01T00:00:00Z"))
        #expect(!String(describing: usage).contains("private-response-key"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `free token resets do not become image resets`(engine: ProviderPluginEngineKind) async throws {
        var data = try Self.data()
        data["plan"] = "free"
        data.removeValue(forKey: "token_expire_time")
        data["token_next_refresh_time"] = "2026-10-21T16:00:00Z"
        let usage = try await Self.fetch(Self.body(data), engine: engine)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == Self.date("2026-10-21T16:00:00Z"))
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `trial rewards and combined legacy totals never invent recurring plan quotas`(
        engine: ProviderPluginEngineKind) async throws
    {
        var data = try Self.data()
        data["unified_token_usage_details"] = [
            ["type": "plan", "token_usage": 0, "token_limit": 0],
            ["type": "trial", "token_usage": 100, "token_limit": 500],
        ]
        let trial = try await Self.fetch(Self.body(data), engine: engine)
        #expect(trial.primary == nil)
        #expect(!trial.details.flatMap(\.rows).contains { $0.label == "Next plan reset" })
        data.removeValue(forKey: "unified_token_usage_details")
        let legacy = try await Self.fetch(Self.body(data), engine: engine)
        #expect(legacy.primary == nil)
        #expect(legacy.details.first?.rows.first?.value == "1,200 / 1,500")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired disabled and terminal periods retain balances without claiming a reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        for status in ["expired", "disabled", "refunded", "unknown"] {
            var data = try Self.data()
            data["status"] = status
            let usage = try await Self.fetch(Self.body(data), engine: engine)
            #expect(usage.primary == nil)
            #expect(usage.secondary?.usedPercent == 12.5)
        }
        for next in ["0001-01-01T00:00:00Z", "invalid", "2026-09-01T00:00:00Z", "2027-01-01T00:00:00Z"] {
            var data = try Self.data()
            data["token_next_refresh_time"] = next
            let usage = try await Self.fetch(Self.body(data), engine: engine)
            #expect(usage.primary?.resetsAt == nil)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `exhaustion clamps progress while absent optional pools stay unknown`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(#"""
        {"data":{"name":"Fixture plan","status":"active","unified_token_usage_details":
        [{"type":"plan","token_usage":1200,"token_limit":1000}]}}
        """#, engine: engine)
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.secondary == nil)
        #expect(usage.details.first?.rows.first?.value == "0 / 1,000")
        #expect(!usage.details.flatMap(\.rows).contains { $0.label == "Image Generation" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `empty pools stay hidden while exhausted balances remain visible`(
        engine: ProviderPluginEngineKind) async throws
    {
        var data = try Self.data()
        data["expansion_pack_usage"] = 0
        data["expansion_pack_limit"] = 0
        data["image_used_count"] = 20
        let usage = try await Self.fetch(Self.body(data), engine: engine)
        #expect(usage.secondary == nil)
        #expect(!usage.details.flatMap(\.rows).contains { $0.label == "Top-up credits" })
        #expect(usage.details.flatMap(\.rows).first { $0.label == "Image Generation" }?.value == "0 / 20")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reward fallback excludes expired grants and never inherits plan resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        var data = try Self.data()
        data.removeValue(forKey: "aggregated_reward_details")
        data["unified_token_usage_details"] = [
            ["type": "plan", "token_usage": 200, "token_limit": 1000],
            ["type": "invitation_reward", "token_usage": 100, "token_limit": 500],
            [
                "type": "trial",
                "token_usage": 25,
                "token_limit": 200,
                "expires_at": "2026-11-01T00:00:00Z",
            ],
            [
                "type": "invitation_reward",
                "token_usage": 0,
                "token_limit": 900,
                "expires_at": "2026-10-19T00:00:00Z",
            ],
        ]
        let usage = try await Self.fetch(Self.body(data), engine: engine)
        let rewards = try #require(usage.details.flatMap(\.rows).first { $0.label == "Credits" })
        #expect(rewards.value == "575 / 700")
        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.extraRateWindows == nil)
        #expect(usage.tertiary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired plan dates retain balances without a primary meter`(
        engine: ProviderPluginEngineKind) async throws
    {
        var data = try Self.data()
        data["token_expire_time"] = "2026-10-19T00:00:00Z"
        let usage = try await Self.fetch(Self.body(data), engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.details.flatMap(\.rows).first { $0.label == "Plan" }?.value == "800 / 1,000")
        #expect(usage.secondary?.usedPercent == 12.5)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed payloads fail without echoing secrets`(engine: ProviderPluginEngineKind) async {
        for body in [
            "private-response-key",
            "null",
            "[]",
            "{}",
            #"{"data":{}}"#,
            #"{"data":{"unified_token_usage":-1,"unified_token_limit":100}}"#,
            #"{"data":{"unified_token_usage":true,"unified_token_limit":100}}"#,
            #"{"data":{"unified_token_usage":9007199254740992,"unified_token_limit":100}}"#,
            #"{"data":{"unified_token_usage_details":{}}}"#,
            #"{"data":null,"error":{"message":"private-response-key"}}"#,
            #"{"data":{"unified_token_usage":0,"unified_token_limit":100},"error":{"code":"fixture-error"}}"#,
            #"""
            {"data":{"unified_token_usage_details":[
            {"type":"plan","token_usage":0,"token_limit":1},
            {"type":"plan","token_usage":0,"token_limit":1}]}}
            """#,
            #"""
            {"data":{"unified_token_usage_details":[
            {"type":"reward","token_usage":0,"token_limit":9007199254740991},
            {"type":"trial","token_usage":0,"token_limit":1}]}}
            """#,
        ] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures preserve authentication and transient error classifications`(
        engine: ProviderPluginEngineKind) async
    {
        for (status, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
            (403, .permissionDenied),
            (409, .apiFailure),
            (429, .rateLimited),
            (500, .providerUnavailable),
            (502, .providerUnavailable),
            (503, .providerUnavailable),
        ] {
            await Self.expectFailure("private-response-key", engine: engine, status: status, kind: kind)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `realtime conflict responses do not assume all status retry semantics`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = CallCount()
        let runtime = try BundledPluginTestSupport.runtime(
            "chatbox", engine: engine, transport: ProviderHTTPTransportHandler { request in
                _ = calls.increment()
                return try Self.response(request, body: #"{"error":{"code":"fixture-conflict"}}"#, status: 409)
            })
        do {
            _ = try await runtime.fetchUsage(secrets: ["CHATBOX_LICENSE_KEY": "fixture-key"], now: Self.now)
            Issue.record("Expected a classified conflict")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure)
        }
        #expect(calls.value == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `absent license status retains the public client quota shape`(
        engine: ProviderPluginEngineKind) async throws
    {
        var data = try Self.data()
        data.removeValue(forKey: "status")
        let usage = try await Self.fetch(Self.body(data), engine: engine)
        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.resetsAt == Self.date("2026-11-01T00:00:00Z"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero allowances stay explicit without an unlimited meter`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            #"{"data":{"unified_token_usage":0,"unified_token_limit":0}}"#, engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.details.first?.rows.map(\.value) == ["0 / 0"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed manual keys fail before any HTTP request`(engine: ProviderPluginEngineKind) async throws {
        for key in ["fixture key", "fixture\r\nheader", "fixture\u{0}suffix", String(repeating: "x", count: 4097)] {
            let runtime = try BundledPluginTestSupport.runtime(
                "chatbox", engine: engine, transport: ProviderHTTPTransportHandler { _ in
                    Issue.record("An invalid manual key must not reach HTTP")
                    throw ProviderPluginError.script("unexpected HTTP request")
                })
            do {
                _ = try await runtime.fetchUsage(secrets: ["CHATBOX_LICENSE_KEY": key], now: Self.now)
                Issue.record("Expected the manual key to be rejected")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .authenticationExpired)
                #expect(error.message == "Chatbox AI license key is invalid. Update it in Settings.")
                #expect(!error.message.contains(key))
            }
        }
    }

    @Test
    func `registration uses existing manual credentials without desktop discovery`() throws {
        let descriptor = ChatboxProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        let adapter = try #require(descriptor.credentials)
        let automatic = ["HOME": "/synthetic/chatbox-home", "CHATBOX_CONFIG_PATH": "/synthetic/profile.json"]
        #expect(adapter.resolveToken(environment: automatic) == nil)
        #expect(!adapter.diagnosticAuthSummary(
            account: nil, config: nil, environment: automatic, settings: nil).configured)
        let manual = automatic.merging(["CHATBOX_LICENSE_KEY": " fixture-key "]) { _, new in new }
        #expect(adapter.resolveToken(environment: manual)?.token == "fixture-key")
        #expect(adapter.resolveToken(environment: manual)?.source == .environment)
        let env = adapter.applyConfig(base: [:], config: ProviderConfig(id: .chatbox, apiKey: "saved-fixture-key"))
        #expect(env["CHATBOX_LICENSE_KEY"] == "saved-fixture-key")
        #expect(ChatboxProviderDescriptor.spec.apiKeyField?.title == "API key")
        let values = try #require(ChatboxProviderDescriptor.spec.scriptValues(ProviderCutoverTestSupport.context(
            environment: manual)))
        let messages = try #require(values.settings["MESSAGES"])
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(messages.utf8))
        #expect(Set(decoded.keys) == Set(ChatboxProviderDescriptor.diagnosticMessages))
    }

    @Test
    func `Chatbox guidance and toggle are translated in every app catalog`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/CodexBar/Resources")
        let catalogs = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(catalogs.count == 23)
        for url in catalogs {
            let catalog = try #require(NSDictionary(contentsOf: url.appendingPathComponent("Localizable.strings"))
                as? [String: String])
            for key in ChatboxProviderDescriptor.diagnosticMessages + ["Show Chatbox AI usage"] {
                let value = try #require(catalog[key], "Missing \(url.lastPathComponent): \(key)")
                #expect(!value.isEmpty)
                if url.lastPathComponent != "en.lproj" { #expect(value != key) }
            }
        }
    }

    private static func data() throws -> [String: Any] {
        let root = try #require(JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as? [String: Any])
        return try #require(root["data"] as? [String: Any])
    }

    private final class CallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() -> Int {
            self.lock.withLock {
                self.count += 1
                return self.count
            }
        }
    }

    private static func body(_ data: [String: Any]) throws -> String {
        try #require(String(data: JSONSerialization.data(withJSONObject: ["data": data]), encoding: .utf8))
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, HTTPURLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "30"]))
        return (Data(body.utf8), response)
    }

    private static func fetch(_ body: String, engine: ProviderPluginEngineKind) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime(
            "chatbox", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.chatboxai.app/api/license/detail/realtime")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                #expect(request.httpBody == nil)
                return try Self.response(request, body: body)
            })
        return try await runtime.fetchUsage(secrets: ["CHATBOX_LICENSE_KEY": "fixture-key"], now: Self.now)
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            let runtime = try BundledPluginTestSupport.runtime(
                "chatbox", engine: engine, transport: ProviderHTTPTransportHandler { request in
                    try Self.response(request, body: body, status: status)
                })
            _ = try await runtime.fetchUsage(secrets: ["CHATBOX_LICENSE_KEY": "fixture-key"], now: Self.now)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            let message = switch kind {
            case .authenticationExpired:
                "Chatbox AI license key is invalid. Update it in Settings. (HTTP 401)"
            case .permissionDenied:
                "Chatbox AI denied access. Check your license. (HTTP 403)"
            case .rateLimited:
                "Chatbox AI is rate limiting requests. Try again later. (HTTP 429)"
            case .parseFailure:
                "Chatbox AI returned an unrecognized response. Update CodexBar and try again."
            default:
                "Chatbox AI request failed. Try refreshing later. (HTTP \(status))"
            }
            #expect(error.message == message)
            #expect(!error.message.contains("private-response-key"))
            #expect(!error.message.contains("fixture-key"))
            if status == 429 { #expect(error.retryAfterSeconds == 10) }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
