import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct LinkupPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance stays separate from the monthly top up cap`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"{"balance":123.456}"#, engine: engine)
        #expect(snapshot.details.first?.rows.first?.label == "Credit balance")
        #expect(snapshot.details.first?.rows.first?.value == "$123.46")
        #expect(snapshot.details.first?.rows.count == 1)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.identity?.loginMethod == "API")
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero and negative numeric balances are preserved`(engine: ProviderPluginEngineKind) async throws {
        for (value, expected) in [("0", "$0.00"), ("-1.25", "-$1.25")] {
            let snapshot = try await Self.fetch(#"{"balance":\#(value)}"#, engine: engine)
            #expect(snapshot.details.first?.rows.first?.value == expected)
            #expect(snapshot.primary == nil)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing malformed and nonfinite balances fail closed`(engine: ProviderPluginEngineKind) async {
        let bodies = ["private-response", "null", "[]", "{}", #"{"balance":1e400}"#]
            + ["null", "true", "\"12\"", "{}", "[]"].map { #"{"balance":\#($0)}"# }
        for body in bodies {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors retain classification without echoing private bodies`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
    }

    @Test
    func `credentials stay explicit and provider defaults off`() throws {
        let descriptor = LinkupProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.balanceOnly)
        #expect(credentials.resolveToken(environment: ["LINKUP_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["LINKUP_API_KEY": "  "]) == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            if code == 429 { #expect(error.retryAfterSeconds == 0) }
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        _ body: String, engine: ProviderPluginEngineKind, code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "linkup", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.linkup.so/v1/credits/balance")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["LINKUP_API_KEY": "fixture-key"])
    }
}
