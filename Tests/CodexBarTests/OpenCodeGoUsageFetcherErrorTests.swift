import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct OpenCodeGoUsageFetcherErrorTests {
    @Test
    func `dashboard URL uses normalized workspace ID`() {
        #expect(
            OpenCodeGoUsageFetcher.dashboardURL(workspaceID: "https://opencode.ai/workspace/wrk_abc123/go")
                .absoluteString == "https://opencode.ai/workspace/wrk_abc123/go")
        #expect(
            OpenCodeGoUsageFetcher.dashboardURL(workspaceID: "workspace=wrk_def456")
                .absoluteString == "https://opencode.ai/workspace/wrk_def456/go")
        #expect(
            OpenCodeGoUsageFetcher.dashboardURL(workspaceID: nil)
                .absoluteString == "https://opencode.ai")
    }

    private struct UsageWindow {
        let percent: Double
        let resetInSec: Int
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeGoStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test
    func `extracts api error from detail field`() async throws {
        defer {
            OpenCodeGoStubURLProtocol.handler = nil
        }

        OpenCodeGoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = #"{"detail":"Workspace missing"}"#
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "application/json")
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected OpenCodeGoUsageError.apiError")
        } catch let error as OpenCodeGoUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("HTTP 500"))
                #expect(message.contains("Workspace missing"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }
    }

    @Test
    func `workspace get missing ids falls back to post before loading go page`() async throws {
        defer {
            OpenCodeGoStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeGoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            let workspaceServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
            if url.query?.contains(workspaceServerID) == true,
               request.httpMethod?.uppercased() == "GET"
            {
                return Self.makeResponse(
                    url: url,
                    body: #"{"ok":true}"#,
                    statusCode: 200,
                    contentType: "application/json")
            }

            if url.path == "/_server",
               request.httpMethod?.uppercased() == "POST",
               request.value(forHTTPHeaderField: "X-Server-Id") == workspaceServerID
            {
                return Self.makeResponse(
                    url: url,
                    body: #"{"data":[{"id":"wrk_TEST123"}]}"#,
                    statusCode: 200,
                    contentType: "application/json")
            }

            return Self.makeResponse(
                url: url,
                body: Self.goUsagePageHTML(
                    workspaceID: "wrk_TEST123",
                    rolling: UsageWindow(percent: 22, resetInSec: 300),
                    weekly: UsageWindow(percent: 44, resetInSec: 3600),
                    monthly: UsageWindow(percent: 55, resetInSec: 7200)),
                statusCode: 200,
                contentType: "text/html")
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 22)
        #expect(snapshot.weeklyUsagePercent == 44)
        #expect(snapshot.monthlyUsagePercent == 55)
        #expect(methods == ["GET", "POST", "GET"])
    }

    @Test
    func `workspace get public actor error is treated as invalid credentials without post retry`() async throws {
        defer {
            OpenCodeGoStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeGoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")
            let body = [
                #";0x00000263;((self.$R=self.$R||{})["server-fn:test"]=[],"#,
                #"($R=>$R[0]=Object.assign(new Error("actor of type \"public\" is not associated with an account"),"#,
                #"{stack:"Error: actor of type \"public\" is not associated with an account"}))"#,
                #"($R["server-fn:test"]))"#,
            ].joined()
            return Self.makeResponse(
                url: url,
                body: body,
                statusCode: 200,
                contentType: "text/javascript")
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                session: self.makeSession())
            Issue.record("Expected OpenCodeGoUsageError.invalidCredentials")
        } catch let error as OpenCodeGoUsageError {
            switch error {
            case .invalidCredentials:
                break
            default:
                Issue.record("Expected invalidCredentials, got: \(error)")
            }
        }

        #expect(methods == ["GET"])
    }

    @Test
    func `go page missing usage fields returns parse failed without post retry`() async throws {
        defer {
            OpenCodeGoStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeGoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")
            return Self.makeResponse(
                url: url,
                body: "<html><title>opencode</title><body>No usage yet</body></html>",
                statusCode: 200,
                contentType: "text/html")
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected OpenCodeGoUsageError.parseFailed")
        } catch let error as OpenCodeGoUsageError {
            switch error {
            case let .parseFailed(message):
                #expect(message.contains("Missing usage fields"))
            default:
                Issue.record("Expected parseFailed, got: \(error)")
            }
        }

        #expect(methods == ["GET"])
    }

    @Test
    func `normalizes workspace override from URL into go page path`() async throws {
        defer {
            OpenCodeGoStubURLProtocol.handler = nil
        }

        var observedPath: String?
        OpenCodeGoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            observedPath = url.path
            return Self.makeResponse(
                url: url,
                body: Self.goUsagePageHTML(
                    workspaceID: "wrk_URL123",
                    rolling: UsageWindow(percent: 17, resetInSec: 600),
                    weekly: UsageWindow(percent: 75, resetInSec: 7200),
                    monthly: nil),
                statusCode: 200,
                contentType: "text/html")
        }

        _ = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "https://opencode.ai/workspace/wrk_URL123/billing",
            session: self.makeSession())

        #expect(observedPath == "/workspace/wrk_URL123/go")
    }

    @Test
    func `fetcher sends only auth cookie to opencode host`() async throws {
        defer {
            OpenCodeGoStubURLProtocol.handler = nil
        }

        var observedCookie: String?
        OpenCodeGoStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            observedCookie = request.value(forHTTPHeaderField: "Cookie")
            return Self.makeResponse(
                url: url,
                body: Self.goUsagePageHTML(
                    workspaceID: "wrk_TEST123",
                    rolling: UsageWindow(percent: 17, resetInSec: 600),
                    weekly: UsageWindow(percent: 75, resetInSec: 7200),
                    monthly: nil),
                statusCode: 200,
                contentType: "text/html")
        }

        _ = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "provider=google; auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123",
            session: self.makeSession())

        #expect(observedCookie == "auth=test")
    }

    private static func goUsagePageHTML(
        workspaceID: String,
        rolling: UsageWindow,
        weekly: UsageWindow,
        monthly: UsageWindow?) -> String
    {
        let monthlyField: String? = if let monthly {
            #"monthlyUsage:{status:"ok",resetInSec:\#(monthly.resetInSec),usagePercent:\#(monthly.percent)}"#
        } else {
            nil
        }

        let usageFields = [
            #"rollingUsage:{status:"ok",resetInSec:\#(rolling.resetInSec),usagePercent:\#(rolling.percent)}"#,
            #"weeklyUsage:{status:"ok",resetInSec:\#(weekly.resetInSec),usagePercent:\#(weekly.percent)}"#,
            monthlyField,
        ]
            .compactMap(\.self)
            .joined(separator: ",")

        return """
        <!DOCTYPE html>
        <html>
        <body>
        <script>
        _$HY.r["lite.subscription.get[\\"\(workspaceID)\\"]"]=$R[17]=$R[2]($R[18]={p:0,s:0,f:0});
        $R[24]($R[18],$R[27]={mine:!0,useBalance:!1,\(usageFields)});
        </script>
        </body>
        </html>
        """
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int,
        contentType: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, Data(body.utf8))
    }
}

final class OpenCodeGoStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opencode.ai"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
