import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OpenDesignPluginTests {
    private static let current = #"""
    {"workspaceId":"workspace-fixture","workspaceName":"Synthetic workspace","personalMembershipTier":"go"}
    """#
    private static let fiveHour = #"""
    {"durationSeconds":18000,"usedCredits":"500","limitCredits":"50000",
     "remainingCredits":"49500","resetsAt":"2026-10-22T04:29:30Z"}
    """#
    private static let weekly = #"""
    {"durationSeconds":604800,"usedCredits":"10451","limitCredits":"150000",
     "remainingCredits":"139549","resetsAt":"2026-10-28T18:29:30Z"}
    """#
    private static let now = Date(timeIntervalSince1970: 1_792_637_753)

    private static func usage(
        _ windows: [String],
        workspace: String = "workspace-fixture",
        eligible: Bool = true) -> String
    {
        """
        {"workspaceId":"\(workspace)","eligible":\(eligible),"tier":"go","windows":[\(windows.joined(separator: ","))]}
        """
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `workspace quota windows use duration rather than response order`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(body: Self.usage([Self.weekly, Self.fiveHour]))
        let usage = try await Self.fetch(engine, fixture)
        #expect(usage.primary?.usedPercent == 1)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.quotaLimit == 50000)
        #expect(usage.primary?.quotaUnit == "credits")
        #expect(abs((usage.secondary?.usedPercent ?? 0) - 6.967_333_333) < 0.000_001)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.quotaLimit == 150_000)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-22T04:29:30Z"))
        #expect(usage.secondary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-28T18:29:30Z"))
        #expect(usage.identity?.accountOrganization == "Synthetic workspace")
        #expect(usage.identity?.accountID == "workspace-fixture")
        #expect(usage.identity?.loginMethod == "go")
        #expect(usage.providerCost == nil)
        #expect(await fixture.paths == [
            "/api/v1/workspaces/current",
            "/api/v1/workspaces/workspace-fixture/billing/coding-plan-usage",
        ])
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero usage is measured and missing resets stay unknown`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.usage([#"{"durationSeconds":18000,"usedCredits":"0","limitCredits":"50000"}"#])
        let usage = try await Self.fetch(engine, Fixture(body: body))
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid quotas and mismatched workspaces cannot produce a snapshot`(engine: ProviderPluginEngineKind) async {
        let bodies = [
            Self.usage([Self.fiveHour], workspace: "another-workspace"),
            Self.usage([Self.fiveHour, Self.fiveHour]),
            Self.usage([#"{"durationSeconds":18000,"usedCredits":"invalid","limitCredits":"50000"}"#]),
            Self.usage([#"{"durationSeconds":18000,"usedCredits":"0","limitCredits":"0"}"#]),
            Self.usage([#"{"durationSeconds":18000,"usedCredits":null,"limitCredits":"50000"}"#]),
        ]
        for body in bodies {
            await #expect {
                try await Self.fetch(engine, Fixture(body: body))
            } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .parseFailure }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `ineligible or unknown windows are unavailable instead of empty allowances`(
        engine: ProviderPluginEngineKind) async
    {
        for body in [Self.usage([], eligible: false), Self.usage([])] {
            await #expect {
                try await Self.fetch(engine, Fixture(body: body))
            } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .providerUnavailable }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected sessions retry but stop after the first validated workspace`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(body: Self.usage([Self.fiveHour]), rejectFirst: true)
        let usage = try await Self.fetch(engine, fixture)
        #expect(usage.primary?.usedPercent == 1)
        #expect(await fixture.sessions == 2)
        #expect(await fixture.paths.count == 3)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing failures preserve classification without exposing response bodies`(
        engine: ProviderPluginEngineKind) async
    {
        for (status, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
            (403, .permissionDenied), (429, .rateLimited), (503, .providerUnavailable), (200, .parseFailure),
        ] {
            let fixture = Fixture(body: "private-response-sentinel", status: status)
            await #expect {
                try await Self.fetch(engine, fixture)
            } throws: { error in
                guard let error = error as? ProviderFetchClassifiedError else { return false }
                return error.kind == kind && !error.message.contains("private-response-sentinel")
                    && !error.message.contains("synthetic-cookie")
            }
            #expect(await fixture.sessions == (status == 401 ? 3 : 1))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `diagnostics use translations supplied by the host`(engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture(body: "private-response", status: 403)
        let runtime = try BundledPluginTestSupport.runtime("opendesign", engine: engine, transport: fixture)
        let localized = "Accesso alla fatturazione di OpenDesign negato."
        let messages = try JSONEncoder().encode(["OpenDesign billing access was denied.": localized])
        await #expect(throws: ProviderFetchClassifiedError(kind: .permissionDenied, message: localized)) {
            try await runtime.fetchUsage(
                settings: ["MESSAGES": String(decoding: messages, as: UTF8.self)],
                cookieSessionResolver: { _, _ in await fixture.nextSession() })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing sessions and disabled cookies never send a request`(engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture(body: Self.usage([]))
        let runtime = try BundledPluginTestSupport.runtime("opendesign", engine: engine, transport: fixture)
        await #expect {
            try await runtime.fetchUsage(cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Disabled cookies reached the broker")
                return nil
            })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
        await #expect {
            try await runtime.fetchUsage(cookieSessionResolver: { _, _ in nil })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
        #expect(await fixture.paths.isEmpty)
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.cache == .nonpersistent)
        #expect(policy.requiredCookies.isEmpty)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
    }

    private static func fetch(_ engine: ProviderPluginEngineKind, _ fixture: Fixture) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime("opendesign", engine: engine, transport: fixture)
        return try await runtime.fetchUsage(now: Self.now, cookieSessionResolver: { _, _ in
            await fixture.nextSession()
        })
    }

    private actor Fixture: ProviderHTTPTransport {
        let body: String
        let status: Int
        let rejectFirst: Bool
        var sessions = 0
        var paths: [String] = []

        init(body: String, status: Int = 200, rejectFirst: Bool = false) {
            self.body = body
            self.status = status
            self.rejectFirst = rejectFirst
        }

        func nextSession() -> ProviderPluginCookieSession? {
            self.sessions += 1
            guard self.sessions <= 2 else { return nil }
            return .init(
                header: "__Secure-better-auth.session_token=synthetic-cookie-\(self.sessions)",
                source: "Synthetic", origin: "https://amr-api.open-design.ai")
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url.host == "amr-api.open-design.ai")
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-cookie-\(self.sessions)") == true)
            self.paths.append(url.path)
            let isCurrent = url.path == "/api/v1/workspaces/current"
            if !isCurrent {
                #expect(url.path == "/api/v1/workspaces/workspace-fixture/billing/coding-plan-usage")
                #expect(request.value(forHTTPHeaderField: "X-Vela-Workspace-Id") == "workspace-fixture")
            }
            let status = self.rejectFirst && self.sessions == 1 ? 401 : isCurrent ? 200 : self.status
            let body = isCurrent ? OpenDesignPluginTests.current : self.body
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }
}
