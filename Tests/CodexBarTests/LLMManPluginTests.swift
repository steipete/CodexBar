import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct LLMManPluginTests {
    /// `GET /llmman/node` with synthetic models: 8 GB + 2 GB loaded of 40 GB model memory.
    static let node = """
    {"memory":40000000000,
     "loaded":{"fixture/small:Q4_K_M":2000000000,"fixture/large:Q4_K_M":8000000000},
     "stored":{"fixture/small:Q4_K_M":2000000000,"fixture/large:Q4_K_M":8000000000,"fixture/idle":500000000}}
    """

    @Test(arguments: BundledPluginTestSupport.engines)
    func `loaded weights fill the memory bar and list largest first`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetDescription == "10.0 GB of 40.0 GB")
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.identity?.providerID == .llmman)
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.dataConfidence == .exact)
        let summary = try #require(snapshot.details.first)
        #expect(summary.rows.map(\.label) == ["Loaded", "Stored", "Version"])
        #expect(summary.rows.map(\.value) == ["2 · 10.0 GB", "3 · 10.5 GB", "0.9.0"])
        let loaded = try #require(snapshot.details.last)
        #expect(loaded.title == "Loaded models")
        #expect(loaded.rows.map(\.label) == ["fixture/large:Q4_K_M", "fixture/small:Q4_K_M"])
        #expect(loaded.rows.map(\.value) == ["8.0 GB", "2.0 GB"])
        #expect(loaded.rows.first?.progress?.usedPercent == 20)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `open daemon needs no key and idle daemon is still displayable`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine,
            key: nil,
            body: #"{"memory":0,"loaded":{},"stored":{}}"#,
            version: nil)
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Local daemon")
        #expect(snapshot.details.count == 1)
        #expect(snapshot.details.first?.rows.map(\.value) == ["0 · 0 B", "0 · 0 B"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `base URL accepts a trailing slash or the OpenAI v1 path`(engine: ProviderPluginEngineKind) async throws {
        for base in ["http://127.0.0.1:17434/", "http://127.0.0.1:17434/v1", "http://192.168.1.10:17434"] {
            _ = try await Self.fetch(engine: engine, base: base)
        }
    }

    @Test(arguments: [
        #"not json"#,
        #"[]"#,
        #"{"memory":-1,"loaded":{},"stored":{}}"#,
        #"{"memory":1,"loaded":[],"stored":{}}"#,
        #"{"memory":1,"loaded":{"a":"1"},"stored":{}}"#,
        #"{"memory":1,"loaded":{}}"#,
    ], BundledPluginTestSupport.engines)
    func `malformed node responses are parse failures`(body: String, engine: ProviderPluginEngineKind) async throws {
        do {
            _ = try await Self.fetch(engine: engine, body: body)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    static let failures: [(Int, String?, ProviderFetchClassifiedError.Kind)] = [
        (401, "fixture-key", .authenticationExpired),
        (401, nil, .missingCredential),
        (404, "fixture-key", .apiFailure),
        (429, "fixture-key", .rateLimited),
        (503, "fixture-key", .providerUnavailable),
    ]

    @Test(arguments: Self.failures, BundledPluginTestSupport.engines)
    func `HTTP failures are classified`(
        argument: (Int, String?, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async throws
    {
        do {
            _ = try await Self.fetch(engine: engine, key: argument.1, status: argument.0)
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == argument.2)
            #expect(!error.message.contains("fixture-key"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `stopped daemon is a network failure naming the address`(engine: ProviderPluginEngineKind) async throws {
        let transport = ProviderHTTPTransportHandler { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await BundledPluginTestSupport.runtime("llmman", engine: engine, transport: transport)
                .fetchUsage(settings: ["LLMMAN_HOST": "http://127.0.0.1:17434"])
            Issue.record("Expected network failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .networkFailure)
            #expect(error.message.contains("http://127.0.0.1:17434"))
        }
    }

    @Test
    func `address follows LLMMAN_HOST and rejects unsafe overrides`() {
        #expect(LLMManSettingsReader.baseURL(environment: [:])?.absoluteString == "http://127.0.0.1:17434")
        #expect(LLMManSettingsReader.baseURL(environment: ["LLMMAN_HOST": "127.0.0.1:18000"])?
            .absoluteString == "http://127.0.0.1:18000")
        #expect(LLMManSettingsReader.baseURL(environment: ["LLMMAN_HOST": "https://llmman.example.com"])?
            .absoluteString == "https://llmman.example.com")
        #expect(LLMManSettingsReader.baseURL(environment: ["LLMMAN_HOST": "http://llmman.example.com"]) == nil)
        #expect(LLMManSettingsReader.baseURL(environment: ["LLMMAN_HOST": "http://u:p@127.0.0.1:17434"]) == nil)
    }

    static func fetch(
        engine: ProviderPluginEngineKind,
        base: String = "http://127.0.0.1:17434",
        key: String? = "fixture-key",
        status: Int = 200,
        body: String = Self.node,
        version: String? = "0.9.0") async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.path == "/llmman/node" || url.path == "/api/version")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == key.map { "Bearer \($0)" })
            let reply = url.path == "/api/version"
                ? version.map { #"{"version":"\#($0)","pid":1}"# } ?? "{}"
                : body
            return try (Data(reply.utf8), #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        return try await BundledPluginTestSupport.runtime("llmman", engine: engine, transport: transport)
            .fetchUsage(
                settings: ["LLMMAN_HOST": base],
                secrets: key.map { ["LLMMAN_API_KEY": $0] } ?? [:])
    }
}
