import Foundation
import Testing
@testable import CodexBarCore

struct TinyApiPluginTests {
    @Test
    func `manifest identity resolves to the registered provider`() {
        #expect(UsageProvider(rawValue: "tinyapi") == .tinyapi)
        #expect(ProviderInstanceID(rawValue: "tinyapi")?.firstPartyProvider == .tinyapi)
    }

    @Test(arguments: [0.0, 125.0, 125.25], BundledPluginTestSupport.engines)
    func `available credits preserve their unit without inventing monthly usage`(
        balance: Double,
        engine: ProviderPluginEngineKind) async throws
    {
        let body = #"{"success":true,"data":{"totalAvailable":\#(balance)}}"#
        let usage = try await Self.fetch(body: body, engine: engine)
        let row = try #require(usage.details.first?.rows.first)
        #expect(row.label == "Available credits")
        #expect(row.usageValue == balance)
        #expect(row.value.hasSuffix(" credits"))
        #expect(!row.value.contains("$"))
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.identity?.loginMethod == "Browser session")
        #expect(usage.identity?.accountEmail == nil)
        let encoded = try JSONEncoder().encode(usage)
        #expect(try #require(String(bytes: encoded, encoding: .utf8)).contains("synthetic-session") == false)
    }

    @Test(
        arguments: [
            "null", "[]", "{}", "<html>sign in</html>",
            #"{"success":false,"data":{"totalAvailable":50}}"#,
            #"{"success":true,"data":{}}"#,
            #"{"success":true,"data":{"totalAvailable":null}}"#,
            #"{"success":true,"data":{"totalAvailable":"50"}}"#,
            #"{"success":true,"data":{"totalAvailable":false}}"#,
            #"{"success":true,"data":{"totalAvailable":-1}}"#,
            #"{"success":true,"data":{"totalAvailable":1e999}}"#,
        ],
        BundledPluginTestSupport.engines)
    func `malformed credit envelopes never fabricate a balance`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await CookiePluginFixtures.expectFailure(.parseFailure) {
            try await Self.fetch(body: body, engine: engine)
        }
    }

    @Test(
        arguments: [
            (400, ProviderFetchClassifiedError.Kind.apiFailure),
            (401, .authenticationExpired), (403, .authenticationExpired),
            (429, .rateLimited), (503, .providerUnavailable),
        ],
        BundledPluginTestSupport.engines)
    func `HTTP failures are classified without exposing response contents`(
        failure: (Int, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(body: "synthetic-private-error", status: failure.0, engine: engine)
            Issue.record("Expected a classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == failure.1)
            #expect(!error.localizedDescription.contains("synthetic-private-error"))
            #expect(!error.localizedDescription.contains("synthetic-session"))
        } catch {
            Issue.record("Expected a classified provider failure")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `off never imports a cookie or sends a request`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.noRequestRuntime(engine: engine)
        await CookiePluginFixtures.expectFailure(.missingCredential) {
            try await runtime.fetchUsage(cookieSource: .off, cookieResolver: { _, _ in
                Issue.record("Off must not import a cookie")
                return "__Secure-authjs.session-token=synthetic-session"
            })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing sessions produce setup guidance without a request`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.noRequestRuntime(engine: engine)
        await CookiePluginFixtures.expectFailure(.missingCredential) {
            try await runtime.fetchUsage(cookieSessionResolver: { _, _ in nil })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected automatic sessions advance to the next profile`(engine: ProviderPluginEngineKind) async throws {
        let sessions = SessionQueue()
        let rejected = LockIsolated<[String]>([])
        let runtime = try BundledPluginTestSupport.runtime(
            "tinyapi",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let expired = request.value(forHTTPHeaderField: "Cookie")?.contains("expired") == true
                return try CookiePluginFixtures.response(
                    request,
                    body: expired
                        ? #"{"success":false,"error":{"code":"UNAUTHORIZED","message":"Not authenticated"}}"#
                        : #"{"success":true,"data":{"totalAvailable":42}}"#,
                    status: expired ? 401 : 200)
            })
        let usage = try await runtime.fetchUsage(
            cookieSessionResolver: { _, _ in await sessions.next() },
            cookieSessionInvalidator: { domain, id in
                #expect(domain == "tinyapi.rest")
                rejected.setValue(rejected.value + [id])
            })
        #expect(usage.details.first?.rows.first?.usageValue == 42)
        #expect(rejected.value.count == 1)
    }

    private static func fetch(
        body: String,
        status: Int = 200,
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "tinyapi",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://tinyapi.rest/api/user/credits")
                #expect(request.httpMethod == "GET")
                #expect(request.httpBody == nil)
                #expect(request
                    .value(forHTTPHeaderField: "Cookie") == "__Secure-authjs.session-token=synthetic-session")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
                return try CookiePluginFixtures.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(cookieSource: .manual, cookieResolver: { provider, domain in
            #expect(provider == .tinyapi)
            #expect(domain == "tinyapi.rest")
            return "__Secure-authjs.session-token=synthetic-session"
        })
    }

    private static func noRequestRuntime(engine: ProviderPluginEngineKind) throws -> ProviderPluginRuntime {
        try BundledPluginTestSupport.runtime(
            "tinyapi",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("No usable session must not send a request")
                throw URLError(.badURL)
            })
    }

    private actor SessionQueue {
        var tokens = ["expired", "valid"]

        func next() -> ProviderPluginCookieSession? {
            guard !self.tokens.isEmpty else { return nil }
            return .init(
                header: "__Secure-authjs.session-token=\(self.tokens.removeFirst())",
                source: "fixture",
                origin: "https://tinyapi.rest")
        }
    }
}
