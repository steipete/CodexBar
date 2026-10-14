import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ParallelPluginTests {
    static let endpoint = "https://platform.parallel.ai/api/rpc/billing/payments/refresh-balance"
    static let cookie = "st=fixture-session; soid=fixture-org"
    /// Shape of the dashboard's refresh-balance response, with synthetic cents.
    static let balanceWithPendingDebit = #"{"kind":"ok","data":{"balance":12345,"pendingDebitBalanceCents":150}}"#

    struct Reply {
        var body: String
        var status = 200
        var headers = ["Content-Type": "application/json"]
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance and pending debit are shown in dollars`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine)
        let details = try #require(snapshot.details.first)
        #expect(details.title == "Account balance")
        #expect(details.rows.map(\.label) == ["Balance", "Pending debit"])
        #expect(details.rows.map(\.value) == ["$123.45", "$1.50"])
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.identity?.loginMethod == "Browser session")
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test
    func `menu bar balance layouts show the dollar balance`() async throws {
        let snapshot = try await Self.fetch(engine: .quickJS)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .parallel, snapshot: snapshot) == "$123.45")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero or missing pending debit leaves only the balance row`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            #"{"kind":"ok","data":{"balance":0,"pendingDebitBalanceCents":0}}"#,
            #"{"kind":"ok","data":{"balance":0}}"#,
            #"{"kind":"ok","data":{"balance":0,"pendingDebitBalanceCents":"5"}}"#,
        ] {
            let rows = try #require(try await Self.fetch(.init(body: body), engine: engine).details.first?.rows)
            #expect(rows.map(\.label) == ["Balance"])
            #expect(rows.map(\.value) == ["$0.00"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `signed out responses expire the session and reject the cookie`(
        engine: ProviderPluginEngineKind) async
    {
        let replies: [Reply] = [
            .init(body: #"{"error":"Unauthorized","loginUrl":"/login"}"#, status: 401),
            .init(body: "private-response", status: 403),
            .init(body: "", status: 302, headers: ["Location": "https://platform.parallel.ai/login"]),
            .init(body: "<html>private-response</html>", headers: ["Content-Type": "text/html; charset=utf-8"]),
        ]
        let expired = "Parallel session expired. Sign in to platform.parallel.ai again or paste a fresh Cookie header."
        for reply in replies {
            let rejected = LockIsolated<[String]>([])
            await Self.expectFailure(reply, engine: engine, kind: .authenticationExpired, rejected: rejected) {
                #expect($0 == expired)
            }
            #expect(rejected.value == ["platform.parallel.ai"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `server errors report the provider as unavailable and other statuses as API failures`(
        engine: ProviderPluginEngineKind) async
    {
        for (status, kind) in [
            (408, ProviderFetchClassifiedError.Kind.providerUnavailable),
            (500, .providerUnavailable),
            (503, .providerUnavailable),
            (400, .apiFailure),
            (404, .apiFailure),
        ] {
            await Self.expectFailure(.init(body: "private-response", status: status), engine: engine, kind: kind) {
                #expect($0 == "Parallel returned HTTP \(status).")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rate limit retry delay is capped at ten seconds`(engine: ProviderPluginEngineKind) async throws {
        for (header, expected) in [("3", 3.0), ("120", 10.0), ("soon", 1.0)] {
            let reply = Reply(
                body: "private-response",
                status: 429,
                headers: ["Content-Type": "application/json", "Retry-After": header])
            do {
                _ = try await Self.fetch(reply, engine: engine)
                Issue.record("Expected a rate limit for Retry-After \(header)")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .rateLimited)
                #expect(error.retryAfterSeconds == expected)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `changed response formats fail parsing instead of reporting zero`(engine: ProviderPluginEngineKind) async {
        let bodies = [
            #"{"kind":"error","data":{"balance":12345}}"#,
            #"{"data":{"balance":12345}}"#,
            #"{"kind":"ok","data":{}}"#,
            #"{"kind":"ok","data":{"balance":"12345"}}"#,
            #"{"kind":"ok","data":{"balance":""}}"#,
            #"{"kind":"ok","data":{"balance":null}}"#,
            #"{"kind":"ok","data":{"balance":1e400}}"#,
            #"{"kind":"ok"}"#,
            "null",
            "[]",
            "private-response",
        ]
        for body in bodies {
            await Self.expectFailure(.init(body: body), engine: engine, kind: .parseFailure) {
                #expect($0 == "Parallel billing response format changed.")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired browser sessions advance to the next candidate`(engine: ProviderPluginEngineKind) async throws {
        let sent = LockIsolated<[String]>([])
        let rejected = LockIsolated<[String]>([])
        let sessions = LockIsolated(["st=expired", Self.cookie])
        let runtime = try BundledPluginTestSupport.runtime(
            "parallel", engine: engine, transport: ProviderHTTPTransportHandler { request in
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                sent.setValue(sent.value + [cookie])
                return cookie == Self.cookie
                    ? try Self.response(request, .init(body: Self.balanceWithPendingDebit))
                    : try Self.response(request, .init(body: #"{"error":"Unauthorized"}"#, status: 401))
            })
        let snapshot = try await runtime.fetchUsage(
            cookieSessionResolver: { _, _ in
                guard let header = sessions.value.first else { return nil }
                sessions.setValue(Array(sessions.value.dropFirst()))
                return .init(header: header, source: "fixture", origin: "https://platform.parallel.ai")
            },
            cookieSessionInvalidator: { domain, _ in rejected.setValue(rejected.value + [domain]) })
        #expect(snapshot.details.first?.rows.first?.value == "$123.45")
        #expect(sent.value == ["st=expired", Self.cookie])
        #expect(rejected.value == ["platform.parallel.ai"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing sessions and disabled cookies never send a request`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "parallel", engine: engine, transport: ProviderHTTPTransportHandler { _ in
                Issue.record("No request may be sent without a session")
                throw URLError(.badURL)
            })
        await CookiePluginFixtures.expectFailure(.missingCredential) {
            try await runtime.fetchUsage(cookieSessionResolver: { _, _ in nil })
        }
        await CookiePluginFixtures.expectFailure(.missingCredential) {
            try await runtime.fetchUsage(cookieSource: .off, cookieResolver: { _, _ in
                Issue.record("Disabled cookies must not be imported")
                return Self.cookie
            })
        }
    }

    @Test
    func `provider is off by default and reads only the browser session`() {
        let descriptor = ParallelProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.balanceOnly)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
    }

    private static func expectFailure(
        _ reply: Reply,
        engine: ProviderPluginEngineKind,
        kind: ProviderFetchClassifiedError.Kind,
        rejected: LockIsolated<[String]>? = nil,
        message check: (String) -> Void) async
    {
        do {
            _ = try await self.fetch(reply, engine: engine, rejected: rejected)
            Issue.record("Expected \(kind) for HTTP \(reply.status)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-session"))
            check(error.message)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    static func response(_ request: URLRequest, _ reply: Reply) throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: reply.headers))
        return (Data(reply.body.utf8), response)
    }

    static func fetch(
        _ reply: Reply = Reply(body: Self.balanceWithPendingDebit),
        engine: ProviderPluginEngineKind,
        rejected: LockIsolated<[String]>? = nil) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "parallel", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == Self.endpoint)
                #expect(request.httpMethod == "POST")
                #expect(request.httpBody == Data("{}".utf8))
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Cookie") == Self.cookie)
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://platform.parallel.ai")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return try Self.response(request, reply)
            })
        return try await runtime.fetchUsage(
            cookieSource: .manual,
            cookieInvalidator: { domain in rejected?.setValue((rejected?.value ?? []) + [domain]) },
            cookieResolver: { _, _ in Self.cookie })
    }
}
