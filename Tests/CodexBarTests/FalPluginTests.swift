import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct FalPluginTests {
    /// Documented `GET /v1/account/billing?expand=credits` schema with synthetic values.
    static let fixture = #"{"username":"fixture-team","credits":{"current_balance":42.5,"currency":"USD"}}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `credit balance and account name are parsed`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(Self.fixture, engine: engine)
        #expect(snapshot.details.first?.title == "Account balance")
        #expect(snapshot.details.first?.rows.map(\.label) == ["Credit balance"])
        #expect(snapshot.details.first?.rows.first?.value == "$42.50")
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.identity?.accountOrganization == "fixture-team")
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero numeric string and other currencies are preserved`(engine: ProviderPluginEngineKind) async throws {
        for (credits, expected) in [
            (#"{"current_balance":0,"currency":"USD"}"#, "$0.00"),
            (#"{"current_balance":"12.75","currency":"USD"}"#, "$12.75"),
            (#"{"current_balance":7,"currency":"EUR"}"#, "€7.00"),
            (#"{"current_balance":3,"currency":"usd-ish"}"#, "$3.00"),
        ] {
            let snapshot = try await Self.fetch(#"{"username":"fixture-team","credits":\#(credits)}"#, engine: engine)
            #expect(snapshot.details.first?.rows.first?.value == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing username keeps the balance without an organization`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"{"credits":{"current_balance":1,"currency":"USD"}}"#, engine: engine)
        #expect(snapshot.details.first?.rows.first?.value == "$1.00")
        #expect(snapshot.identity?.accountOrganization == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a response without the credits block is a temporary outage`(engine: ProviderPluginEngineKind) async {
        for body in [
            #"{"username":"fixture-team"}"#, #"{"username":"fixture-team","credits":null}"#,
            #"{"username":"fixture-team","credits":"private-response"}"#, #"{"credits":[]}"#,
        ] {
            await Self.expectFailure(body, engine: engine, kind: .providerUnavailable) { message in
                #expect(message.contains("did not return the credit balance"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unusable balances fail parsing and name the received type`(engine: ProviderPluginEngineKind) async {
        for (balance, kind) in [
            ("null", "null"), ("true", "boolean"), (#""private-response""#, "string"), (#""""#, "string"),
            ("[]", "array"), ("{}", "object"), ("1e400", "number"),
        ] {
            let body = #"{"username":"fixture-team","credits":{"current_balance":\#(balance),"currency":"USD"}}"#
            await Self.expectFailure(body, engine: engine, kind: .parseFailure) { message in
                #expect(message.contains("(\(kind))"))
            }
        }
        await Self.expectFailure(#"{"credits":{"currency":"USD"}}"#, engine: engine, kind: .parseFailure)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed bodies fail closed`(engine: ProviderPluginEngineKind) async {
        for body in ["private-response", "null", "[]", "42"] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors retain classification without echoing private bodies`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind) { message in
                if code == 403 { #expect(message.contains("billing:usage:read")) }
            }
        }
    }

    @Test
    func `credentials stay explicit and provider defaults off`() throws {
        let descriptor = FalProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.balanceOnly)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(credentials.resolveToken(environment: ["FAL_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["FAL_KEY": "  "]) == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind,
        message check: (String) -> Void = { _ in }) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code)
            Issue.record("Expected classified failure for \(body)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-key"))
            check(error.message)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    static func fetch(
        _ body: String = Self.fixture,
        engine: ProviderPluginEngineKind,
        code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "fal", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.fal.ai/v1/account/billing?expand=credits")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Key fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["FAL_KEY": "fixture-key"])
    }
}
