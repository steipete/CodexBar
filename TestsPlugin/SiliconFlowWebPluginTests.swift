import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SiliconFlowWebPluginTests {
    private static let denied = "SiliconFlow denied access to the console balance (HTTP 403). "
        + "Open cloud.siliconflow.cn, check that this account can view billing, then refresh."

    private static func wallet(balance: String = #""12500000000000""#) -> String {
        let totals = #","available":"1","recharged":"400000000000000","used":"387500000000000""#
        return #"{"code":20000,"data":{"financialInfo":{"balance":\#(balance)\#(totals)}}}"#
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing page header supplies the subject for the same session's wallet query`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(wallet: Self.wallet())
        let result = try await Self.fetch(engine, fixture)
        let usage = result.usage
        #expect(usage.detailRow(label: "Balance")?.value == "CN¥12.50")
        #expect(usage.details.flatMap(\.rows).count == 1)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        let requests = await fixture.requests
        #expect(requests.map(\.path) == ["/me/expensebill", "/walletd-server/api/v1/subject/profile/peek"])
        #expect(requests[0].subject == nil)
        #expect(requests[0].accept == "text/html")
        #expect(requests[1].subject == "subject-fixture")
        #expect(requests.map(\.cookie) == ["sf-session-1", "sf-session-1"])
        #expect(result.validated.isEmpty)
        #expect(result.rejected.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `wallet amounts convert exactly from picoyuan strings`(engine: ProviderPluginEngineKind) async throws {
        for (balance, expected) in [
            (#""0""#, "CN¥0.00"),
            (#""-1500000000000""#, "-CN¥1.50"),
            (#""98765432100000000000000""#, "CN¥98,765,432,100.00"),
        ] {
            let usage = try await Self.fetch(engine, Fixture(wallet: Self.wallet(balance: balance))).usage
            #expect(usage.detailRow(label: "Balance")?.value == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing subjects and malformed wallets never publish a balance`(engine: ProviderPluginEngineKind) async {
        let fixtures = [
            Fixture(wallet: Self.wallet(), subject: nil),
            Fixture(wallet: Self.wallet(), subject: ""),
            Fixture(wallet: Self.wallet(), subject: "bad subject"),
            Fixture(wallet: "private-response-sentinel"),
            Fixture(wallet: #"{"code":20000,"data":{}}"#),
            Fixture(wallet: #"{"code":1,"data":{"financialInfo":{"balance":"1"}}}"#),
            Fixture(wallet: Self.wallet(balance: #""""#)),
            Fixture(wallet: Self.wallet(balance: #""1.5""#)),
            Fixture(wallet: Self.wallet(balance: "12")),
            Fixture(wallet: Self.wallet(balance: "null")),
        ]
        for fixture in fixtures {
            await #expect {
                try await Self.fetch(engine, fixture)
            } throws: { error in
                guard let error = error as? ProviderFetchClassifiedError else { return false }
                return error.kind == .parseFailure && !error.message.contains("private-response-sentinel")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `login redirects reject the stale session and try the next candidate`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(wallet: Self.wallet(), loginRedirectSessions: [1])
        let result = try await Self.fetch(engine, fixture)
        #expect(result.usage.detailRow(label: "Balance")?.value == "CN¥12.50")
        #expect(await fixture.requests.map(\.cookie) == ["sf-session-1", "sf-session-2", "sf-session-2"])
        #expect(result.rejected.count == 1)
        #expect(result.validated.isEmpty)
        #expect(result.rejected != result.validated)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired sessions ask for a browser sign in without exposing the redirect`(
        engine: ProviderPluginEngineKind) async
    {
        for fixture in [
            Fixture(wallet: Self.wallet(), loginRedirectSessions: [1, 2]),
            Fixture(wallet: "private-response-sentinel", walletStatus: 401),
        ] {
            let rejected = Recorder()
            let validated = Recorder()
            await #expect {
                try await Self.fetch(engine, fixture, rejected: rejected, validated: validated)
            } throws: { error in
                guard let error = error as? ProviderFetchClassifiedError else { return false }
                return error.kind == .authenticationExpired
                    && error.message == "Sign in to cloud.siliconflow.cn in your browser, then refresh CodexBar."
                    && !error.message.contains("state-sentinel")
                    && !error.message.contains("private-response-sentinel")
            }
            #expect(await Set(fixture.requests.map(\.cookie)) == ["sf-session-1", "sf-session-2"])
            #expect(rejected.ids.count == 2)
            #expect(validated.ids.isEmpty)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `other failures keep their classification and the session`(engine: ProviderPluginEngineKind) async {
        for (fixture, kind) in [
            (
                Fixture(wallet: "private-response-sentinel", walletStatus: 403),
                ProviderFetchClassifiedError.Kind
                    .permissionDenied),
            (Fixture(wallet: "private-response-sentinel", walletStatus: 429), .rateLimited),
            (Fixture(wallet: "private-response-sentinel", walletStatus: 503), .providerUnavailable),
            (
                Fixture(wallet: Self.wallet(), pageStatus: 302, location: "https://cloud.siliconflow.cn/other"),
                .apiFailure),
            (
                Fixture(wallet: Self.wallet(), pageStatus: 307, location: "https://account.siliconflow.cn.evil/login"),
                .apiFailure),
        ] {
            let rejected = Recorder()
            let validated = Recorder()
            await #expect {
                try await Self.fetch(engine, fixture, rejected: rejected, validated: validated)
            } throws: { error in
                guard let error = error as? ProviderFetchClassifiedError else { return false }
                return error.kind == kind && !error.message.contains("private-response-sentinel")
                    && (kind != .permissionDenied
                        || error.message == Self.denied)
            }
            #expect(rejected.ids.isEmpty)
            #expect(validated.ids.isEmpty)
            #expect(await Set(fixture.requests.map(\.cookie)) == ["sf-session-1"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing sessions and disabled cookies never send a request`(engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture(wallet: Self.wallet())
        let runtime = try BundledPluginTestSupport.runtime("siliconflow-web", engine: engine, transport: fixture)
        await #expect {
            try await runtime.fetchUsage(sourceMode: .web, cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Disabled cookies reached the broker")
                return nil
            })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
        await #expect {
            try await runtime.fetchUsage(sourceMode: .web, cookieSessionResolver: { _, _ in nil })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
        #expect(await fixture.requests.isEmpty)
        #expect(runtime.manifest.endpoints == [.fixed("https://cloud.siliconflow.cn")])
        #expect(runtime.manifest.auth == nil)
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.cache == .nonpersistent)
        #expect(policy.requiredCookies.isEmpty)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `diagnostics use the host supplied translation`(engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture(wallet: Self.wallet(), loginRedirectSessions: [1, 2])
        let runtime = try BundledPluginTestSupport.runtime("siliconflow-web", engine: engine, transport: fixture)
        let key = "Sign in to cloud.siliconflow.cn in your browser, then refresh CodexBar."
        let messages = try JSONEncoder().encode([key: "Localized fixture sign in."])
        await #expect(throws: ProviderFetchClassifiedError(
            kind: .authenticationExpired, message: "Localized fixture sign in."))
        {
            try await runtime.fetchUsage(
                settings: ["MESSAGES": String(decoding: messages, as: UTF8.self)],
                sourceMode: .web,
                cookieSessionResolver: { _, _ in await fixture.nextSession() })
        }
    }

    @Test
    func `production redirect delegate keeps parent domain cookies off the login host`() throws {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "__SF_auth.session-token", .value: "sf-session", .domain: ".siliconflow.cn", .path: "/",
        ]
        properties[.secure] = "TRUE"
        let jar = ProviderPluginCookieJar()
        let session = try ProviderPluginCookieSession(
            header: "",
            source: "Synthetic",
            origin: "https://cloud.siliconflow.cn",
            records: [ProviderPluginCookieRecord(cookie: #require(HTTPCookie(properties: properties)))])
        jar.register(session)
        let delegate = ProviderPluginCookieTransport.CookieRedirectDelegate(jar: jar, id: session.id)
        let original = try #require(URL(string: "https://cloud.siliconflow.cn/me/expensebill"))
        for (raw, cookie) in [
            ("https://cloud.siliconflow.cn/me/expensebill/", "__SF_auth.session-token=sf-session"),
            ("https://account.siliconflow.cn/login?state=state-sentinel", nil),
            ("http://cloud.siliconflow.cn/me/expensebill", nil),
        ] {
            var request = try URLRequest(url: #require(URL(string: raw)))
            request.setValue("__SF_auth.session-token=sf-session", forHTTPHeaderField: "Cookie")
            #expect(
                delegate.redirectedRequest(originalURL: original, request: request)?
                    .value(forHTTPHeaderField: "Cookie") == cookie,
                "\(raw)")
        }
        jar.reject(id: session.id)
        var request = URLRequest(url: original)
        #expect(throws: (any Error).self) { try jar.apply(to: &request, id: session.id) }
        #expect(delegate.redirectedRequest(originalURL: original, request: URLRequest(url: original)) == nil)
    }

    private struct Result {
        let usage: UsageSnapshot
        let validated: [String]
        let rejected: [String]
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        _ fixture: Fixture,
        rejected: Recorder = Recorder(),
        validated: Recorder = Recorder()) async throws -> Result
    {
        let runtime = try BundledPluginTestSupport.runtime("siliconflow-web", engine: engine, transport: fixture)
        let usage = try await runtime.fetchUsage(
            sourceMode: .web,
            cookieSessionResolver: { _, _ in await fixture.nextSession() },
            cookieSessionInvalidator: { _, id in rejected.append(id) },
            cookieSessionValidator: { _, id in validated.append(id) })
        return Result(usage: usage, validated: validated.ids, rejected: rejected.ids)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var ids: [String] {
            self.lock.withLock { self.values }
        }

        func append(_ id: String) {
            self.lock.withLock { self.values.append(id) }
        }
    }

    private struct Request {
        let path: String
        let cookie: String?
        let subject: String?
        let accept: String?
    }

    private actor Fixture: ProviderHTTPTransport {
        let wallet: String
        let walletStatus: Int
        let subject: String?
        let pageStatus: Int
        let location: String?
        let loginRedirectSessions: Set<Int>
        var sessions = 0
        var requests: [Request] = []

        init(
            wallet: String,
            walletStatus: Int = 200,
            subject: String? = "subject-fixture",
            pageStatus: Int = 200,
            location: String? = nil,
            loginRedirectSessions: Set<Int> = [])
        {
            self.wallet = wallet
            self.walletStatus = walletStatus
            self.subject = subject
            self.pageStatus = pageStatus
            self.location = location
            self.loginRedirectSessions = loginRedirectSessions
        }

        func nextSession() -> ProviderPluginCookieSession? {
            self.sessions += 1
            guard self.sessions <= 2 else { return nil }
            return .init(
                header: "__SF_auth.session-token=sf-session-\(self.sessions)",
                source: "Synthetic", origin: "https://cloud.siliconflow.cn")
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url.host == "cloud.siliconflow.cn")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let cookie = request.value(forHTTPHeaderField: "Cookie")?
                .replacingOccurrences(of: "__SF_auth.session-token=", with: "")
            self.requests.append(Request(
                path: url.path,
                cookie: cookie,
                subject: request.value(forHTTPHeaderField: "x-subject-id"),
                accept: request.value(forHTTPHeaderField: "Accept")))
            var headers = ["Content-Type": "text/html; charset=utf-8"]
            var status = 200
            var body = "<html></html>"
            if url.path == "/me/expensebill" {
                if self.loginRedirectSessions.contains(self.sessions) {
                    status = 307
                    headers["Location"] = "https://account.siliconflow.cn/login?state=state-sentinel"
                } else {
                    status = self.pageStatus
                    if let location = self.location { headers["Location"] = location }
                    if let subject = self.subject { headers["X-Subject-Id"] = subject }
                }
            } else {
                #expect(url.path == "/walletd-server/api/v1/subject/profile/peek")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.siliconflow.cn/me/expensebill")
                status = self.walletStatus
                body = self.wallet
                headers["Content-Type"] = "application/json"
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: headers))
            return (Data(body.utf8), response)
        }
    }
}
