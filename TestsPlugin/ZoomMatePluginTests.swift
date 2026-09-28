import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ZoomMatePluginTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let status = #"{"data":{"credit_status":{"budget_cap":1000,"used_credit":250,"cycle_start_date":1799000000000,"cycle_end_date":1801000000000}}}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `bootstrap validates before required usage and native credit history details survive`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = Calls()
        let timestamp = ISO8601DateFormatter().string(from: Self.now)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            calls.append(url.lastPathComponent)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=synthetic")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://zoommate.zoom.us")
            switch url.lastPathComponent {
            case "login":
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return try Self.response(
                    request,
                    body: #"{"data":{"nak":"opaque-fixture","user_profile":{"email":"fixture@example.test"}}}"#)
            case "status":
                #expect(calls.values.contains("validated"))
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-fixture")
                return try Self.response(request, body: Self.status)
            case "history":
                return try Self.response(request, body: """
                {"data":{"total":4,"records":[{"cost":2.5,"time":"\(timestamp)"},
                {"cost":1,"time":"\(timestamp)","is_running":true},
                {"cost":999,"time":"\(timestamp)","is_deleted":true},
                {"cost":-1,"time":"\(timestamp)"}]}}
                """)
            default: throw URLError(.badURL)
            }
        }
        let runtime = try BundledPluginTestSupport.runtime("zoommate", engine: engine, transport: transport)
        let usage = try await runtime.fetchUsage(
            now: Self.now,
            cookieSessionResolver: Self.session,
            cookieSessionValidator: { _, _ in calls.append("validated") })
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "Credits")
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_801_000_000))
        #expect(usage.identity?.accountEmail == "fixture@example.test")
        #expect(usage.identity?.loginMethod == "Cookie")
        let rows = try #require(usage.details.first?.rows)
        #expect(rows.map(\.label) == ["Today", "30d credits", "Pace"])
        #expect(rows.map(\.value) == ["3.5", "3.5", "25% behind budget"])
        #expect(usage.details.first?.chart?.points.map(\.value) == [3.5])
        #expect(calls.values == ["login", "validated", "status", "history"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `bearer cache survives runtime replacement and is invalidated after a rejected history`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = Calls()
        let key = UUID().uuidString
        let payload = Data("{\"exp\":\(Date().timeIntervalSince1970 + 3600)}".utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let token = "fixture.\(payload).signature"
        for attempt in 0..<3 {
            let runtime = try BundledPluginTestSupport.runtime(
                "zoommate",
                engine: engine,
                transport: ProviderHTTPTransportHandler { request in
                    let path = request.url?.lastPathComponent ?? ""
                    calls.append(path)
                    if path == "login" { return try Self.response(
                        request,
                        body: "{\"data\":{\"nak\":\"\(token)\"}}") }
                    return try Self.response(
                        request,
                        code: path == "history" && attempt == 1 ? 401 : 200,
                        body: path == "status" ? Self
                            .status : #"{"data":{"records":[]}}"#)
                })
            _ = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
                .init(header: "session=synthetic", source: "Fixture", origin: "https://ai.zoom.us", cacheKey: key)
            }, cookieSessionValidator: { _, _ in })
        }
        #expect(calls.values.filter { $0 == "login" }.count == 2)
        #expect(calls.values.filter { $0 == "status" }.count == 3)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `host failover preserves leaf scope and optional history failure preserves required usage`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = Calls()
        let runtime = try BundledPluginTestSupport.runtime(
            "zoommate",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                calls.append(url.host ?? "")
                if url
                    .host ==
                    "ai.zoom.us" { throw URLError(.cannotConnectToHost) }
                #expect(request
                    .value(forHTTPHeaderField: "Cookie") ==
                    "session=mate")
                if url
                    .lastPathComponent ==
                    "login" { return try Self.response(
                    request,
                    body: #"{"data":{"nak":"fixture"}}"#) }
                return try Self.response(
                    request,
                    code: url.lastPathComponent == "history" ? 500 : 200,
                    body: Self.status)
            })
        let usage = try await runtime.fetchUsage(now: Self.now, cookieSessionResolver: { _, _ in
            .init(
                header: "",
                source: "Fixture",
                origin: "https://ai.zoom.us",
                headersByHost: ["ai.zoom.us": "session=ai", "zoommate.zoom.us": "session=mate"])
        }, cookieSessionValidator: { _, _ in })
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.details.isEmpty)
        #expect(calls.values == Array(repeating: ["ai.zoom.us", "zoommate.zoom.us"], count: 3).flatMap(\.self))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `bootstrap parse failures do not validate or fail over`(engine: ProviderPluginEngineKind) async throws {
        let calls = Calls()
        let runtime = try BundledPluginTestSupport.runtime(
            "zoommate",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                calls.append(request.url?.host ?? "")
                return try Self.response(request, body: #"{"data":{}}"#)
            })
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(
                cookieSessionResolver: Self.session,
                cookieSessionValidator: { _, _ in
                    Issue.record("Failed bootstrap must not persist")
                })
        }
        #expect(calls.values == ["ai.zoom.us"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual bearer without cookies survives sibling failover without a bootstrap`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "zoommate",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.lastPathComponent != "login")
                #expect(request
                    .value(forHTTPHeaderField: "Authorization") ==
                    "Bearer manual-fixture")
                #expect(request.value(forHTTPHeaderField: "Cookie")?
                    .isEmpty != false)
                if request.url?
                    .host ==
                    "ai.zoom.us" { throw URLError(.cannotConnectToHost) }
                return try Self.response(
                    request,
                    body: request.url?
                        .lastPathComponent == "status" ? Self
                        .status : #"{"data":{"records":[]}}"#)
            })
        let usage = try await runtime.fetchUsage(
            secrets: ["AUTHORIZATION": "manual-fixture"],
            cookieSource: .manual,
            cookieSessionResolver: { _, _ in
                .init(
                    header: "",
                    source: "manual",
                    origin: "https://ai.zoom.us",
                    permitsEmptyHosts: ["ai.zoom.us", "zoommate.zoom.us"])
            })
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.identity?.accountEmail == nil)
        #expect(usage.identity?.loginMethod == nil)
    }

    private static let session: ProviderPluginRuntime.CookieSessionResolver = { _, _ in
        .init(
            header: "session=synthetic",
            source: "Fixture",
            origin: "https://ai.zoom.us",
            headersByHost: ["ai.zoom.us": "session=synthetic", "zoommate.zoom.us": "session=synthetic"])
    }

    private static func response(_ request: URLRequest, code: Int = 200, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        return try (
            Data(body.utf8),
            #require(HTTPURLResponse(
                url: url,
                statusCode: code,
                httpVersion: nil,
                headerFields: nil)))
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] {
            self.lock.withLock { self.storage }
        }

        func append(_ value: String) { self.lock.withLock { self.storage.append(value) } }
    }
}

extension ZoomMatePluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `history pagination restarts on the alternate host`(engine: ProviderPluginEngineKind) async throws {
        let calls = Calls()
        let timestamp = ISO8601DateFormatter().string(from: Self.now)
        let runtime = try BundledPluginTestSupport.runtime(
            "zoommate",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                if url
                    .lastPathComponent ==
                    "status" { return try Self.response(
                    request,
                    body: Self.status) }
                let page = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "page" })?.value ?? "missing"
                calls.append("\(url.host ?? ""): \(page)")
                if url.host == "ai.zoom.us",
                   page == "1" { return try Self.response(
                    request,
                    code: 500,
                    body: "{}") }
                let cost = url.host == "ai.zoom.us" ? 100 : 1
                return try Self.response(request, body: """
                {"data":{"total":101,"records":[{"cost":\(cost),"time":"\(timestamp)"}]}}
                """)
            })
        let usage = try await runtime.fetchUsage(
            secrets: ["AUTHORIZATION": "fixture"],
            now: Self.now,
            cookieSource: .manual,
            cookieSessionResolver: Self.session)
        #expect(calls.values == [
            "ai.zoom.us: 0",
            "ai.zoom.us: 1",
            "zoommate.zoom.us: 0",
            "zoommate.zoom.us: 1",
            "zoommate.zoom.us: 2",
        ])
        #expect(usage.details.first?.rows.first?.value == "3")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `history stops at twenty pages or an entirely older page`(engine: ProviderPluginEngineKind) async throws {
        for old in [false, true] {
            let calls = Calls()
            let timestamp = ISO8601DateFormatter()
                .string(from: old ? Self.now.addingTimeInterval(-40 * 86400) : Self.now)
            let runtime = try BundledPluginTestSupport.runtime(
                "zoommate",
                engine: engine,
                transport: ProviderHTTPTransportHandler { request in
                    if request.url?
                        .lastPathComponent ==
                        "status" { return try Self.response(
                        request,
                        body: Self.status) }
                    calls.append("page")
                    return try Self.response(request, body: """
                    {"data":{"total":99999,"records":[{"cost":1,"time":"\(timestamp)"}]}}
                    """)
                })
            let usage = try await runtime.fetchUsage(
                secrets: ["AUTHORIZATION": "fixture"],
                now: Self.now,
                cookieSource: .manual,
                cookieSessionResolver: Self.session)
            #expect(calls.values.count == (old ? 1 : 20))
            #expect(usage.details.first?.rows.first?.value == (old ? "0" : "20"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `bootstrap auth rejection advances profiles without host failover`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = Calls()
        let sessions = Calls()
        let runtime = try BundledPluginTestSupport.runtime(
            "zoommate",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let cookie = request
                    .value(forHTTPHeaderField: "Cookie") ?? ""
                if cookie == "session=old" {
                    calls.append(request.url?.host ?? "")
                    return try Self.response(
                        request,
                        code: 401,
                        body: "{}")
                }
                let path = request.url?.lastPathComponent ?? ""
                let body = path == "login" ?
                    #"{"data":{"nak":"fixture"}}"# : path == "status" ?
                    Self.status : #"{"data":{"records":[]}}"#
                return try Self.response(request, body: body)
            })
        let usage = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
            let index = sessions.values.count
            guard index < 2 else { return nil }
            sessions.append("candidate")
            let header = index == 0 ? "session=old" : "session=new"
            return .init(
                header: header,
                source: "Fixture",
                origin: "https://ai.zoom.us",
                cachedAt: index == 0 ? 1 : nil)
        }, cookieSessionValidator: { _, _ in })
        #expect(usage.primary?.usedPercent == 25)
        #expect(calls.values == ["ai.zoom.us"])
        #expect(sessions.values.count == 2)
    }
}
