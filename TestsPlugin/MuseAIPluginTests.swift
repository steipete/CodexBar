import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

/// Plugin-engine coverage for the bundled muse.ai subscription script.
struct MuseAIPluginTests {
    static let actionID = "40447f7d32b58c622904d92f8ac01a13f4798568bd"
    static let maximum = #"""
    0:{"a":"$@1","f":"","q":"","i":false}
    1:{"success":true,"subscription":{"tier":{"name":"Maximum"},"usage":{"percentUsed":3,"resetsAt":1790634838},"usageRowValueLabel":"3% used (2.8B tokens left)","topupBalance":60000000,"topupTotal":80000000,"topupRowLabel":"Additional tokens","topupRowValueLabel":"25% used (1.5B tokens left)","agreement":{"currentPeriodEndTime":1790721238}}}
    """#
    static let free = #"""
    1:{"success":true,"subscription":{"tier":{"name":"Muse Free"},"usage":{"percentUsed":28,"resetsAt":1790634838},"usageRowValueLabel":"28% used","agreement":null}}
    """#
    static let chunks = [
        "/": #"<script src="/_next/static/chunks/app.js"></script><script src="/_next/static/chunks/loader.js">"#,
        "/_next/static/chunks/app.js": #"e.A(434304).then(({preloadHatchSettingsData:e})=>e({}))"#,
        "/_next/static/chunks/loader.js": #"},56115,s=>{s.v(t=>Promise.all(["static/chunks/other.js"]))},"#
            + #"434304,s=>{s.v(t=>Promise.all(["static/chunks/settings.js"].map(t=>s.l(t))))}"#,
        "/_next/static/chunks/settings.js":
            #"(0,d.createServerReference)("\#(actionID)",d.callServer,void 0,d.findSourceMapURL,"fetchSubscriptionAction")"#,
    ]

    @Test(arguments: BundledPluginTestSupport.engines)
    func `paid and free plans map weekly usage`(engine: ProviderPluginEngineKind) async throws {
        let paid = try await Self.fetch(engine: engine, storedID: Self.actionID, action: Self.maximum)
        #expect(paid.snapshot.primary?.usedPercent == 3)
        #expect(paid.snapshot.primary?.windowMinutes == 7 * 24 * 60)
        #expect(paid.snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_790_634_838))
        #expect(paid.snapshot.primary?.resetDescription == "2.8B tokens left")
        #expect(paid.snapshot.subscriptionRenewsAt == Date(timeIntervalSince1970: 1_790_721_238))
        #expect(paid.snapshot.identity?.loginMethod == "Maximum")
        #expect(paid.snapshot.identity?.providerID == .museai)
        #expect(paid.requests == ["POST / \(Self.actionID)"])
        let topup = try #require(paid.snapshot.details.first?.rows.first)
        #expect(topup.label == "Additional tokens")
        #expect(topup.value == "1.5B tokens left")
        #expect(topup.progress?.used == 0.25)

        let unlabeled = try await Self.fetch(
            engine: engine,
            storedID: Self.actionID,
            action: Self.maximum.replacing(
                #""topupRowValueLabel":"25% used (1.5B tokens left)""#,
                with: #""topupRowValueLabel":null"#)
                .replacing(
                    #""topupBalance":60000000,"topupTotal":80000000"#,
                    with: #""topupBalance":80000000,"topupTotal":80000000"#))
        #expect(unlabeled.snapshot.details.first?.rows.first?.value == "$80.00 left")

        let power = try await Self.fetch(
            engine: engine, storedID: Self.actionID,
            action: Self.maximum.replacing("Maximum", with: "Power")
                .replacing("2.8B tokens left", with: "473M tokens left")
                .replacing("\"percentUsed\":3", with: "\"percentUsed\":5"))
        #expect(power.snapshot.identity?.loginMethod == "Power")
        #expect(power.snapshot.primary?.usedPercent == 5)
        #expect(power.snapshot.primary?.resetDescription == "473M tokens left")

        let free = try await Self.fetch(engine: engine, storedID: Self.actionID, action: Self.free)
        #expect(free.snapshot.primary?.usedPercent == 28)
        #expect(free.snapshot.primary?.resetDescription == nil)
        #expect(free.snapshot.subscriptionRenewsAt == nil)
        #expect(free.snapshot.identity?.loginMethod == "Muse Free")
        #expect(free.snapshot.details.isEmpty)
    }

    @Test(arguments: [nil, "40aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], BundledPluginTestSupport.engines)
    func `missing or stale actions are rediscovered and saved`(
        storedID: String?,
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            storedID: storedID,
            action: Self.free,
            observeHTTP: { traces in
                let posts = traces.filter { $0.method == "POST" }
                #expect(posts.map(\.status) == (storedID == nil ? [200] : [404, 200]))
                #expect(posts.allSatisfy { $0.contentType == "text/plain;charset=UTF-8" })
                #expect(posts.last?.actionID == Self.actionID)
                if let storedID { #expect(posts.first?.actionID == storedID) }
            })
        #expect(result.snapshot.primary?.usedPercent == 28)
        #expect(result.requests.contains("GET /_next/static/chunks/settings.js"))
        #expect(!result.requests.contains("GET /_next/static/chunks/other.js"))
        #expect(result.requests.last == "POST / \(Self.actionID)")
        #expect(result.storedID == Self.actionID)
    }

    @Test(arguments: [(307, 200), (200, 403)], BundledPluginTestSupport.engines)
    func `sign-in redirects and forbidden actions report an expired session`(
        statuses: (page: Int, action: Int),
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, storedID: nil, action: "", pageStatus: statuses.page, actionStatus: statuses.action)
            Issue.record("Expected an expired session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an expired browser session falls through to the next one`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetch(
            engine: engine, storedID: Self.actionID, action: Self.free,
            cookies: ["hatch_sess=fixture-rejected-session-value", "hatch_sess=fixture"])
        #expect(result.snapshot.primary?.usedPercent == 28)
        #expect(result.rejected == ["hatch_sess=fixture-rejected-session-value"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `discovery caps page chunk requests`(engine: ProviderPluginEngineKind) async {
        let page = (0..<120).map { "<script src=\"/_next/static/chunks/chunk\($0).js\"></script>" }.joined()
        do {
            _ = try await Self.fetch(engine: engine, storedID: nil, action: Self.free, chunks: ["/": page]) {
                requests, _ in
                #expect(requests.filter { $0.hasPrefix("GET /_next/") }.count <= 96)
            }
            Issue.record("Expected discovery failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `discovery caps lazy settings chunks`(engine: ProviderPluginEngineKind) async {
        var chunks = Self.chunks
        let paths = (0..<60).map { "\"static/chunks/settings\($0).js\"" }.joined(separator: ",")
        chunks["/_next/static/chunks/loader.js"] = "},434304,s=>{s.v(t=>Promise.all([\(paths)].map(t=>s.l(t))))}"
        do {
            _ = try await Self.fetch(engine: engine, storedID: nil, action: Self.free, chunks: chunks) { requests, _ in
                #expect(requests.filter { $0.hasPrefix("GET /_next/static/chunks/settings") }.count <= 32)
            }
            Issue.record("Expected discovery failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `failed rediscovery is classified and never caches the unusable action`(
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, storedID: "40aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                action: "Server action not found.",
                actionStatus: 404)
            { requests, stored in
                #expect(requests.filter { $0.hasPrefix("POST") }.count == 2)
                #expect(stored == nil)
            }
            Issue.record("Expected rediscovery failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.localizedDescription.contains("subscription action"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual rejection stays pinned and off performs no requests`(engine: ProviderPluginEngineKind) async {
        do {
            _ = try await Self.fetch(
                engine: engine, storedID: Self.actionID, action: Self.free,
                cookies: ["hatch_sess=fixture-rejected-session-value", "hatch_sess=fixture"], cookieSource: .manual)
            { requests, _ in #expect(requests.count == 1) }
            Issue.record("Expected the manual session to expire")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            _ = try await Self.fetch(engine: engine, storedID: nil, action: Self.free, cookieSource: .off) {
                requests, _ in #expect(requests.isEmpty)
            }
            Issue.record("Expected cookies to be disabled")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid subscription responses never save an action`(engine: ProviderPluginEngineKind) async {
        do {
            _ = try await Self.fetch(engine: engine, storedID: nil, action: "1:{\"success\":false}") {
                _, stored in #expect(stored == nil)
            }
            Issue.record("Expected invalid subscription data")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String] = []
        var httpTraces: [HTTPTrace] = []
        func append(_ entry: String) { self.lock.withLock { self.entries.append(entry) } }
        func append(_ trace: HTTPTrace) { self.lock.withLock { self.httpTraces.append(trace) } }
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        storedID: String?,
        action: String,
        pageStatus: Int = 200,
        actionStatus: Int = 200,
        cookies: [String] = ["hatch_sess=fixture"],
        cookieSource: ProviderCookieSource = .auto,
        chunks: [String: String] = Self.chunks,
        observe: @Sendable ([String], String?) -> Void = { _, _ in },
        observeHTTP: @Sendable ([HTTPTrace]) -> Void = { _ in }) async throws
        -> (snapshot: UsageSnapshot, requests: [String], storedID: String?, rejected: [String])
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("MuseAIPluginTests-\(UUID())")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let file = storage.appendingPathComponent("museai.json")
        if let storedID {
            try Data(#"{"values":{"actionID":"\#(storedID)"},"version":1}"#.utf8).write(to: file)
        }
        let log = Log()
        defer {
            let saved = (try? Data(contentsOf: file)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            observe(log.entries, (saved?["values"] as? [String: String])?["actionID"])
            observeHTTP(log.httpTraces)
            try? FileManager.default.removeItem(at: storage)
        }
        let runtime = try BundledPluginTestSupport.runtime(
            "museai",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let path = request.url?.path ?? ""
                let actionHeader = request.value(forHTTPHeaderField: "Next-Action")
                log.append([request.httpMethod ?? "GET", path, actionHeader].compactMap(\.self).joined(separator: " "))
                var status = 200
                var body = chunks[path] ?? ""
                var headers: [String: String] = [:]
                let expired = request.value(forHTTPHeaderField: "Cookie") == "hatch_sess=fixture-rejected-session-value"
                if request.httpMethod == "POST" {
                    #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
                    (status, body) = expired ? (403, #"{"error":"Forbidden"}"#)
                        : actionHeader == Self.actionID ? (actionStatus, action) : (404, "Server action not found.")
                } else if path == "/" {
                    status = pageStatus
                    if pageStatus == 307 {
                        headers["Location"] = "https://auth.muse.ai/aymh/?origin=https%3A%2F%2Fmuse.ai"
                    }
                } else {
                    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                }
                log.append(HTTPTrace(
                    method: request.httpMethod ?? "GET",
                    path: path,
                    actionID: actionHeader,
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    status: status))
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                return (Data(body.utf8), response)
            },
            storageDirectory: storage)
        let sessions = cookies.map { ProviderPluginCookieSession(
            header: $0,
            source: "Fixture",
            origin: "https://muse.ai") }
        let issued = Log()
        let rejected = Log()
        let snapshot = try await runtime.fetchUsage(
            cookieSource: cookieSource,
            cookieSessionResolver: { _, _ in
                let next = issued.lock.withLock { sessions.dropFirst(issued.entries.count).first }
                if let next { issued.append(next.id) }
                return next
            },
            cookieSessionInvalidator: { _, id in
                rejected.append(sessions.first { $0.id == id }?.header ?? id)
            })
        let saved = try (JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["values"]
        return (snapshot, log.entries, (saved as? [String: String])?["actionID"], rejected.entries)
    }
}

private struct HTTPTrace: Sendable {
    let method: String
    let path: String
    let actionID: String?
    let contentType: String?
    let status: Int
}
