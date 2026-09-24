import Foundation
import Testing
@testable import CodexBarCore

struct ManusPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected cache and browser candidates advance before environment fallback`(
        engine: ProviderPluginEngineKind) async throws
    {
        let rejected = LockIsolated<[String]>([])
        let sessions = SessionQueue(["session_id=cached", "session_id=browser", "session_id=browser"])
        let runtime = try BundledPluginTestSupport.runtime(
            "manus",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { request in
                let token = request.value(forHTTPHeaderField: "Authorization")
                await sessions.record(token ?? "missing")
                return try CookiePluginFixtures.response(
                    request,
                    body: token == "Bearer environment" ? #"{"totalCredits":5}"# : "expired",
                    status: token == "Bearer environment" ? 200 : 401)
            })
        let usage = try await runtime.fetchUsage(
            secrets: ["SESSION_TOKEN": "environment"],
            cookieSessionResolver: { _, _ in await sessions.next() },
            cookieSessionInvalidator: { domain, id in
                #expect(domain == "manus.im")
                rejected.setValue(rejected.value + [id])
            })
        #expect(usage.identity?.loginMethod == "Balance: 5 credits")
        #expect(rejected.value.count == 3)
        #expect(await sessions.attempts == ["Bearer cached", "Bearer browser", "Bearer environment"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual mode never uses environment after rejected credentials`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "manus",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer manual")
                return try CookiePluginFixtures.response(request, body: "expired", status: 403)
            })
        await CookiePluginFixtures.expectFailure(.authenticationExpired) {
            try await runtime.fetchUsage(
                secrets: ["SESSION_TOKEN": "environment"],
                cookieSource: .manual,
                cookieResolver: { _, _ in "manual" })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `off mode never imports cookies or uses environment`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "manus",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { _ in
                Issue.record("Disabled provider must not send a request")
                throw URLError(.badURL)
            })
        await CookiePluginFixtures.expectFailure(.missingCredential) {
            try await runtime.fetchUsage(
                secrets: ["SESSION_TOKEN": "environment"],
                cookieSource: .off,
                cookieResolver: { _, _ in
                    Issue.record("Disabled provider must not import cookies")
                    return "session_id=browser"
                })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `sparse credits and numeric dates retain native projection`(engine: ProviderPluginEngineKind) async throws {
        let body = #"""
        {"totalCredits":"1200","periodicCredits":"300","proMonthlyCredits":1000,
         "refreshCredits":"bad","maxRefreshCredits":100,"nextRefreshTime":0,"refreshInterval":"DAILY REFRESH"}
        """#
        let runtime = try BundledPluginTestSupport.runtime(
            "manus",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { request in
                #expect(request.httpMethod == "POST")
                #expect(request.httpBody == Data("{}".utf8))
                return try CookiePluginFixtures.response(request, body: body)
            })
        let usage = try await runtime.fetchUsage(cookieResolver: { _, _ in "Session_ID = fixture" })
        #expect(usage.primary?.usedPercent == 70)
        #expect(usage.primary?.resetDescription == "Total 1,200 • Free 0")
        #expect(usage.secondary?.usedPercent == 100)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSinceReferenceDate: 0))
        #expect(usage.secondary?.resetDescription == "Daily Refresh: 0 / 100")
    }

    private actor SessionQueue {
        var headers: [String]
        var attempts: [String] = []

        init(_ headers: [String]) { self.headers = headers }

        func next() -> ProviderPluginCookieSession? {
            guard !self.headers.isEmpty else { return nil }
            return .init(header: self.headers.removeFirst(), source: "fixture", origin: "https://manus.im")
        }

        func record(_ token: String) { self.attempts.append(token) }
    }
}
