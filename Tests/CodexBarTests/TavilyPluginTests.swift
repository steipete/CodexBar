import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct TavilyPluginTests {
    static let fixture = #"""
    {"key":{"usage":150,"limit":200},"account":{"current_plan":"Bootstrap",
    "plan_usage":500,"plan_limit":1000,"paygo_usage":25,"paygo_limit":100}}
    """#

    @Test
    func `Tavily requires an explicit provider key and defaults off`() throws {
        let descriptor = TavilyProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.resolveToken(environment: ["TAVILY_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["TAVILY_API_KEY": " \n"])?.token == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"])?.token == nil)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.sessionLabel == "Plan credits")
        #expect(descriptor.metadata.weeklyLabel == "API key")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `account key and paygo credit scopes remain separate`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary?.usedPercent == 50)
        #expect(snapshot.secondary?.usedPercent == 75)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.secondary?.resetsAt == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.map(\.title) == ["Account plan", "API key", "Pay as you go"])
        #expect(snapshot.details[0].rows.map(\.value) == ["500 credits", "1,000 credits", "500 credits"])
        #expect(snapshot.details[1].rows.map(\.value) == ["150 credits", "200 credits", "50 credits"])
        #expect(snapshot.details[2].rows.map(\.value) == ["25 credits", "100 credits", "75 credits"])
        #expect(snapshot.identity?.providerID == .tavily)
        #expect(snapshot.identity?.loginMethod == "Bootstrap")
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unlimited key zero caps and overuse do not invent headroom`(engine: ProviderPluginEngineKind) async throws {
        let unlimited = try await Self.fetch(
            engine: engine, body: Self.fixture.replacingOccurrences(of: #""limit":200"#, with: #""limit":null"#))
        #expect(unlimited.secondary == nil)
        #expect(unlimited.details[1].rows.map(\.value) == ["150 credits", "Unlimited"])
        let zero = try await Self.fetch(
            engine: engine,
            body: Self.fixture
                .replacingOccurrences(of: #""plan_limit":1000"#, with: #""plan_limit":0"#)
                .replacingOccurrences(of: #""limit":200"#, with: #""limit":0"#))
        #expect(zero.primary == nil)
        #expect(zero.secondary == nil)
        #expect(zero.details[0].rows.last?.value == "0 credits")
        let over = try await Self.fetch(
            engine: engine, body: Self.fixture.replacingOccurrences(
                of: #""plan_usage":500"#,
                with: #""plan_usage":1500"#))
        #expect(over.primary?.usedPercent == 100)
        #expect(over.details[0].rows.first?.value == "1,500 credits")
        #expect(over.details[0].rows.last?.value == "0 credits")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero usage and omitted optional paygo preserve valid totals`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine,
            body: #"{"key":{"usage":0,"limit":100},"account":{"plan_usage":0,"plan_limit":1000}}"#)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(snapshot.details.count == 2)
        #expect(snapshot.details[0].rows.last?.value == "1,000 credits")
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed numeric fields and payloads fail without response disclosure`(
        engine: ProviderPluginEngineKind) async throws
    {
        var invalid = ["private-response", "null", "[]", "{}", #"{"key":[],"account":{}}"#]
        for value in ["null", "true", "-1", "1.5", "1e999", "9007199254740992", #""500""#, #""private-response""#] {
            invalid.append(Self.fixture.replacingOccurrences(
                of: #""plan_usage":500"#,
                with: #""plan_usage":\#(value)"#))
        }
        for field in [
            #""usage":150"#, #""limit":200"#, #""plan_limit":1000"#,
            #""paygo_usage":25"#, #""paygo_limit":100"#,
        ] {
            let name = field.split(separator: ":")[0]
            invalid.append(Self.fixture.replacingOccurrences(of: field, with: "\(name):-1"))
        }
        invalid.append(Self.fixture.replacingOccurrences(
            of: #""current_plan":"Bootstrap""#,
            with: #""current_plan":false"#))
        invalid.append(#"{"key":{"usage":0},"account":{"plan_usage":0,"plan_limit":1}}"#)
        invalid.append(#"{"key":{"usage":0,"limit":null},"account":{"plan_usage":0,"plan_limit":1,"paygo_usage":2}}"#)
        for body in invalid {
            do {
                _ = try await Self.fetch(engine: engine, body: body)
                Issue.record("Expected a classified parse failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures are classified without rate limit replay`(engine: ProviderPluginEngineKind) async throws {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            do {
                _ = try await Self.fetch(engine: engine, code: code, body: "private-response")
                Issue.record("Expected a classified HTTP failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == kind)
                #expect(error.message.contains(String(code)))
                #expect(!error.message.contains("private-response"))
                #expect(error.retryAfterSeconds == nil)
            }
        }
    }

    static func fetch(engine: ProviderPluginEngineKind, code: Int = 200, body: String = Self.fixture) async throws
        -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "tavily",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.tavily.com/usage")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.value(forHTTPHeaderField: "X-Project-ID") == nil)
                #expect(request.httpBody == nil)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "60"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["TAVILY_API_KEY": "fixture-key"])
    }
}
