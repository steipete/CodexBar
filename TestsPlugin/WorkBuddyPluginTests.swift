import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

/// Plugin-engine coverage for the bundled WorkBuddy billing script.
struct WorkBuddyPluginTests {
    static let summaryPath = "/billing/meter/get-user-resource-summary"
    static let paidPath = "/billing/meter/get-user-resource-paid-packages"
    static let freePath = "/billing/meter/get-user-resource-free-packages"

    static let summary = #"""
    {
      "code": 0,
      "msg": "OK",
      "requestId": "fixture-request",
      "data": {
        "Packages": [{
          "PackageCode": "FIXTURE_FREE",
          "CycleTotalCapacity": "500",
          "CycleRemainCapacity": "450",
          "CycleUsedCapacity": "50",
          "CycleFrozenCapacity": "0",
          "CapacityUnit": "credits",
          "TotalCount": 1
        }],
        "SubscriptionPackageCode": "",
        "SubscriptionPackageName": "体验版",
        "IsPaidUser": false,
        "IsProtectedPriceUser": false
      }
    }
    """#

    static let emptyPackages = #"{"code":0,"msg":"OK","data":{"Accounts":[],"TotalCount":0}}"#

    static let freePackages = #"""
    {"code":0,"msg":"OK","data":{"TotalCount":1,"Accounts":[{
      "CapacityUnit": "credits",
      "CycleStartTime": "2026-10-01 00:00:00",
      "CycleEndTime": "2026-10-31 23:59:59",
      "Status": 0
    }]}}
    """#

    /// 2026-10-03T00:00:00Z
    static let now = Date(timeIntervalSince1970: 1_790_985_600)
    /// 2026-10-31 23:59:59 China Standard Time, plus one second.
    static let octoberReset = Date(timeIntervalSince1970: 1_793_462_400)

    @Test(arguments: BundledPluginTestSupport.engines)
    func `monthly credits become one meter with plan and cycle reset`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary?.usedPercent == 10)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.primary?.resetsAt == Self.octoberReset)
        #expect(snapshot.primary?.resetDescription == "450 / 500 credits left")
        #expect(snapshot.identity?.providerID == .workbuddy)
        #expect(snapshot.identity?.loginMethod == "体验版")
        #expect(snapshot.details.isEmpty)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `requests post JSON with the website session and no bearer`(engine: ProviderPluginEngineKind) async throws {
        let paths = PathTrace()
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let path = request.url?.path ?? ""
                paths.append(path)
                #expect(request.url?.host == "www.workbuddy.cn")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                #expect(cookie.contains("session=fixture-session"))
                #expect(cookie.contains("locale=zh"))
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.workbuddy.cn")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.workbuddy.cn/profile/plans-usage")
                #expect(request.timeoutInterval == 22)
                #expect(request.value(forHTTPHeaderField: "User-Agent") == Self.chromeUserAgent(154))
                let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
                if path == Self.summaryPath {
                    #expect(body?.isEmpty == true)
                } else {
                    let codes = body?["PackageCodes"] as? [String] ?? []
                    #expect(body?["PageNumber"] as? Int == 1)
                    #expect(body?["PageSize"] as? Int == 100)
                    #expect(body?["Status"] as? [Int] == [0, 3])
                    #expect(codes.contains(path == Self.freePath
                            ? "TCACA_code_008_cfWoLwvjU4"
                            : "TCACA_code_002_AkiJS3ZHF5"))
                    #expect(codes.count == (path == Self.freePath ? 11 : 9))
                }
                return try Self.response(request, body: Self.route(path).1)
            })
        let sessions = SessionTrace(headers: [Self.fixtureCookie])
        _ = try await runtime.fetchUsage(
            settings: ["webTimeoutSeconds": "22", "chromeMajorVersion": "154"],
            now: Self.now,
            cookieSessionResolver: { _, _ in sessions.next() },
            cookieSessionValidator: { _, _ in })
        #expect(paths.values == [Self.summaryPath, Self.paidPath, Self.freePath])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `credit packages are summed and other units ignored`(engine: ProviderPluginEngineKind) async throws {
        let summary = #"""
        {"code":0,"msg":"OK","data":{"SubscriptionPackageName":"专业版","IsPaidUser":true,"Packages":[
          {"CycleTotalCapacity":"2000","CycleRemainCapacity":"1500.5","CycleFrozenCapacity":"12.25","CapacityUnit":"credits"},
          {"CycleTotalCapacity":"500","CycleRemainCapacity":"500","CycleFrozenCapacity":"0","CapacityUnit":"credits"},
          {"CycleTotalCapacity":"9","CycleRemainCapacity":"1","CapacityUnit":"requests"}
        ]}}
        """#
        let snapshot = try await Self.fetch(engine: engine, routes: [Self.summaryPath: (200, summary)])
        #expect(abs((snapshot.primary?.usedPercent ?? 0) - 19.98) < 0.001)
        #expect(snapshot.primary?.resetDescription == "2000.5 / 2500 credits left")
        #expect(snapshot.identity?.loginMethod == "专业版")
        #expect(snapshot.details.first?.rows.map(\.label) == ["Reserved"])
        #expect(snapshot.details.first?.rows.map(\.value) == ["12.25"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `earliest future cycle end across packages is the reset`(engine: ProviderPluginEngineKind) async throws {
        let paid = #"""
        {"code":0,"msg":"OK","data":{"Accounts":[
          {"CapacityUnit":"credits","CycleEndTime":"2026-09-30 23:59:59"},
          {"CapacityUnit":"credits","CycleEndTime":"2026-10-20 23:59:59"},
          {"CapacityUnit":"requests","CycleEndTime":"2026-10-05 23:59:59"},
          {"CapacityUnit":"credits","CycleEndTime":"2026-10-04"}
        ]}}
        """#
        let snapshot = try await Self.fetch(engine: engine, routes: [Self.paidPath: (200, paid)])
        // 2026-10-20 23:59:59 +08:00, plus one second.
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_792_512_000))
    }

    @Test(
        arguments: [(500, "{}"), (200, #"{"code":4001,"msg":"denied"}"#), (200, "not JSON"), (200, #"{"code":0}"#)],
        BundledPluginTestSupport.engines)
    func `failed package listings keep the balance without a reset`(
        failure: (Int, String),
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine,
            routes: [Self.paidPath: failure, Self.freePath: failure])
        #expect(snapshot.primary?.usedPercent == 10)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.primary?.resetDescription == "450 / 500 credits left")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero allowance shows left and total rows instead of a meter`(engine: ProviderPluginEngineKind) async throws {
        let summary = #"""
        {"code":0,"msg":"OK","data":{"SubscriptionPackageName":"体验版","Packages":[
          {"CycleTotalCapacity":"0","CycleRemainCapacity":"0","CapacityUnit":"credits"}
        ]}}
        """#
        let snapshot = try await Self.fetch(engine: engine, routes: [Self.summaryPath: (200, summary)])
        #expect(snapshot.primary == nil)
        #expect(snapshot.details.first?.rows.map(\.label) == ["Left", "Total"])
        #expect(snapshot.details.first?.rows.map(\.value) == ["0", "0"])
        #expect(snapshot.identity?.loginMethod == "体验版")
    }

    @Test(
        arguments: ["true", "-5", "\"\"", "\"NaN\"", "\"1e3\"", "\"-1\"", "[]", "null"],
        BundledPluginTestSupport.engines)
    func `invalid amounts fail instead of publishing a balance`(
        value: String,
        engine: ProviderPluginEngineKind) async
    {
        let summary = """
        {"code":0,"data":{"Packages":[{"CycleTotalCapacity":"500","CycleRemainCapacity":\(value),\
        "CapacityUnit":"credits"}]}}
        """
        await Self.expectFailure(.parseFailure) {
            _ = try await Self.fetch(engine: engine, routes: [Self.summaryPath: (200, summary)])
        }
    }

    @Test(
        arguments: ["not JSON", "[]", #"{"code":0}"#, #"{"code":0,"data":{}}"#, #"{"code":0,"data":{"Packages":{}}}"#],
        BundledPluginTestSupport.engines)
    func `malformed summaries stay unavailable`(body: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure) {
            _ = try await Self.fetch(engine: engine, routes: [Self.summaryPath: (200, body)])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `non zero summary codes are API failures`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.apiFailure) {
            _ = try await Self.fetch(
                engine: engine,
                routes: [Self.summaryPath: (200, #"{"code":10001,"msg":"fixture"}"#)])
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable),
        (404, .apiFailure),
    ], BundledPluginTestSupport.engines)
    func `summary failures retain actionable classification`(
        failure: (Int, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(failure.1) {
            _ = try await Self.fetch(engine: engine, routes: [Self.summaryPath: (failure.0, "<html></html>")])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `empty browser import is a missing credential`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Must not fetch without a session cookie")
                throw ProviderPluginError.secretAccess("unreachable")
            })
        await Self.expectFailure(.missingCredential) {
            _ = try await runtime.fetchUsage(
                now: Self.now,
                cookieSessionResolver: { _, _ in nil },
                cookieSessionValidator: { _, _ in })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected candidates advance within the same refresh`(engine: ProviderPluginEngineKind) async throws {
        let sessions = SessionTrace(headers: ["session=rejected-fixture", Self.fixtureCookie])
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
                let path = request.url?.path ?? ""
                if path == Self
                    .summaryPath { sessions.request(header.contains("rejected-fixture") ? "rejected" : "valid") }
                let rejected = header.contains("rejected-fixture")
                return try Self.response(request, body: Self.route(path).1, status: rejected ? 401 : 200)
            })
        let usage = try await runtime.fetchUsage(
            now: Self.now,
            cookieSessionResolver: { domain, _ in
                #expect(domain == "www.workbuddy.cn")
                return sessions.next()
            },
            cookieSessionInvalidator: { domain, id in
                #expect(domain == "www.workbuddy.cn")
                sessions.reject(id)
            },
            cookieSessionValidator: { _, _ in })
        #expect(usage.primary?.usedPercent == 10)
        #expect(sessions.requested == ["rejected", "valid"])
        #expect(sessions.rejected == [sessions.candidates[0].id])
    }

    @Test(arguments: [ProviderCookieSource.manual, .off], BundledPluginTestSupport.engines)
    func `manual and off never advance to another account`(
        source: ProviderCookieSource, engine: ProviderPluginEngineKind) async throws
    {
        let sessions = SessionTrace(headers: ["session=rejected-fixture", Self.fixtureCookie])
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                sessions.request(request.value(forHTTPHeaderField: "Cookie") ?? "")
                return try Self.response(request, body: "{}", status: 401)
            })
        await Self.expectFailure(source == .off ? .missingCredential : .authenticationExpired) {
            _ = try await runtime.fetchUsage(
                now: Self.now,
                cookieSource: source,
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) },
                cookieSessionValidator: { _, _ in })
        }
        #expect(sessions.consumed == (source == .off ? 0 : 1))
        #expect(sessions.requested.count == (source == .off ? 0 : 1))
    }

    @Test(arguments: [403, 429, 503], BundledPluginTestSupport.engines)
    func `non authentication errors preserve the candidate and stop retries`(
        status: Int, engine: ProviderPluginEngineKind) async throws
    {
        let sessions = SessionTrace(headers: [Self.fixtureCookie, "session=other"])
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                sessions.request(request.value(forHTTPHeaderField: "Cookie") ?? "")
                return try Self.response(request, body: "{}", status: status)
            })
        let expected: ProviderFetchClassifiedError.Kind = switch status {
        case 403: .permissionDenied
        case 429: .rateLimited
        default: .providerUnavailable
        }
        await Self.expectFailure(expected) {
            _ = try await runtime.fetchUsage(
                now: Self.now,
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) },
                cookieSessionValidator: { _, _ in })
        }
        #expect(sessions.consumed == 1)
        #expect(sessions.requested.count == 1)
        #expect(sessions.rejected.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a pending Chrome update retries the previous major user agent`(
        engine: ProviderPluginEngineKind) async throws
    {
        let agents = PathTrace()
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let path = request.url?.path ?? ""
                let agent = request.value(forHTTPHeaderField: "User-Agent") ?? "none"
                if path == Self.summaryPath { agents.append(agent) }
                let accepted = agent == Self.chromeUserAgent(153)
                return try Self.response(request, body: Self.route(path).1, status: accepted ? 200 : 401)
            })
        let sessions = SessionTrace(headers: [Self.fixtureCookie])
        let usage = try await runtime.fetchUsage(
            settings: ["chromeMajorVersion": "154"],
            now: Self.now,
            cookieSessionResolver: { _, _ in sessions.next() },
            cookieSessionValidator: { _, _ in })
        #expect(agents.values == [Self.chromeUserAgent(154), Self.chromeUserAgent(153)])
        #expect(usage.primary?.resetsAt == Self.octoberReset)
        #expect(sessions.rejected.isEmpty)
    }

    @Test(arguments: ["154", nil], BundledPluginTestSupport.engines)
    func `a session rejected for every user agent is expired`(
        version: String?, engine: ProviderPluginEngineKind) async throws
    {
        let agents = PathTrace()
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                agents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "none")
                return try Self.response(request, body: "{}", status: 401)
            })
        let sessions = SessionTrace(headers: [Self.fixtureCookie])
        await Self.expectFailure(.authenticationExpired) {
            _ = try await runtime.fetchUsage(
                settings: version.map { ["chromeMajorVersion": $0] } ?? [:],
                now: Self.now,
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) },
                cookieSessionValidator: { _, _ in })
        }
        #expect(agents.values == (version == nil
                ? ["none"]
                : [Self.chromeUserAgent(154), Self.chromeUserAgent(153)]))
        #expect(sessions.rejected == [sessions.candidates[0].id])
    }

    @Test(arguments: [ProviderCookieSource.auto, .manual], BundledPluginTestSupport.engines)
    func `only an accepted automatic session is cached`(
        source: ProviderCookieSource, engine: ProviderPluginEngineKind) async throws
    {
        let sessions = SessionTrace(headers: [Self.fixtureCookie])
        let accepted = PathTrace()
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: Self.route(request.url?.path ?? "").1)
            })
        _ = try await runtime.fetchUsage(
            now: Self.now,
            cookieSource: source,
            cookieSessionResolver: { _, _ in sessions.next() },
            cookieSessionValidator: { domain, id in accepted.append("\(domain):\(id)") })
        #expect(accepted.values == (source == .auto ? ["www.workbuddy.cn:\(sessions.candidates[0].id)"] : []))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `cookie policy keeps values in the host and admits gated background reads`(
        engine: ProviderPluginEngineKind) throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy", engine: engine,
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.badURL) })
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.selection == .requestURL)
        #expect(policy.cache == .validatedSingleEntry)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
        #expect(policy.allowsImportAttempt(runtime: .cli, interaction: .userInitiated))
    }

    private final class PathTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ path: String) { self.lock.withLock { self.paths.append(path) } }
        var values: [String] {
            self.lock.withLock { self.paths }
        }
    }

    private final class SessionTrace: @unchecked Sendable {
        let candidates: [ProviderPluginCookieSession]
        private let lock = NSLock()
        private var index = 0
        private var requests: [String] = []
        private var rejections: [String] = []

        init(headers: [String]) {
            self.candidates = headers.map {
                ProviderPluginCookieSession(header: $0, source: "Fixture", origin: "https://www.workbuddy.cn")
            }
        }

        func next() -> ProviderPluginCookieSession? {
            self.lock.withLock {
                guard self.index < self.candidates.count else { return nil }
                defer { self.index += 1 }
                return self.candidates[self.index]
            }
        }

        func request(_ header: String) { self.lock.withLock { self.requests.append(header) } }
        func reject(_ id: String) { self.lock.withLock { self.rejections.append(id) } }
        var consumed: Int {
            self.lock.withLock { self.index }
        }

        var requested: [String] {
            self.lock.withLock { self.requests }
        }

        var rejected: [String] {
            self.lock.withLock { self.rejections }
        }
    }

    private static func chromeUserAgent(_ major: Int) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(major).0.0.0 Safari/537.36"
    }

    private static func route(_ path: String) -> (Int, String) {
        switch path {
        case self.summaryPath: (200, self.summary)
        case self.freePath: (200, self.freePackages)
        default: (200, self.emptyPackages)
        }
    }

    static func fetch(
        engine: ProviderPluginEngineKind,
        routes: [String: (Int, String)] = [:]) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let path = request.url?.path ?? ""
                let (status, body) = routes[path] ?? Self.route(path)
                return try Self.response(request, body: body, status: status)
            })
        let sessions = SessionTrace(headers: [Self.fixtureCookie])
        return try await runtime.fetchUsage(
            now: Self.now,
            cookieSessionResolver: { domain, _ in
                #expect(domain == "www.workbuddy.cn")
                return sessions.next()
            },
            cookieSessionValidator: { _, _ in })
    }

    private static let fixtureCookie = "session=fixture-session; locale=zh"

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        perform: () async throws -> Void) async
    {
        do {
            try await perform()
            Issue.record("Expected classified failure \(kind)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
