import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct OpenCodeUsageFetcherErrorTests {
    @Test
    func extractsApiErrorFromUppercaseHTMLTitle() async throws {
        let registered = URLProtocol.registerClass(OpenCodeStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenCodeStubURLProtocol.self)
            }
            OpenCodeStubURLProtocol.handler = nil
        }

        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = "<html><head><TITLE>403 Forbidden</TITLE></head><body>denied</body></html>"
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "text/html")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123")
            Issue.record("Expected OpenCodeUsageError.apiError")
        } catch let error as OpenCodeUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("HTTP 500"))
                #expect(message.contains("403 Forbidden"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }
    }

    @Test
    func extractsApiErrorFromDetailField() async throws {
        let registered = URLProtocol.registerClass(OpenCodeStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenCodeStubURLProtocol.self)
            }
            OpenCodeStubURLProtocol.handler = nil
        }

        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = #"{"detail":"Workspace missing"}"#
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "application/json")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123")
            Issue.record("Expected OpenCodeUsageError.apiError")
        } catch let error as OpenCodeUsageError {
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
    func subscriptionGetNullSkipsPostAndReturnsGracefulError() async throws {
        let registered = URLProtocol.registerClass(OpenCodeStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenCodeStubURLProtocol.self)
            }
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        var urls: [URL] = []
        var queries: [String] = []
        var contentTypes: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")
            urls.append(url)
            queries.append(url.query ?? "")
            contentTypes.append(request.value(forHTTPHeaderField: "Content-Type") ?? "")

            if request.httpMethod?.uppercased() == "GET" {
                return Self.makeResponse(url: url, body: "null", statusCode: 200, contentType: "application/json")
            }

            let body = #"{"status":500,"unhandled":true,"message":"HTTPError"}"#
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "application/json")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123")
            Issue.record("Expected OpenCodeUsageError.apiError")
        } catch let error as OpenCodeUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("No subscription usage data"))
                #expect(message.contains("wrk_TEST123"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }

        #expect(methods == ["GET"])
        #expect(queries[0].contains("id="))
        #expect(queries[0].contains("wrk_TEST123"))
        #expect(urls[0].path == "/_server")
        #expect(contentTypes[0].isEmpty)
    }

    @Test
    func subscriptionGetPayloadDoesNotFallbackToPost() async throws {
        let registered = URLProtocol.registerClass(OpenCodeStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenCodeStubURLProtocol.self)
            }
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            let body = """
            {
              "rollingUsage": { "usagePercent": 17, "resetInSec": 600 },
              "weeklyUsage": { "usagePercent": 75, "resetInSec": 7200 }
            }
            """
            return Self.makeResponse(url: url, body: body, statusCode: 200, contentType: "application/json")
        }

        let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123")

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.weeklyUsagePercent == 75)
        #expect(methods == ["GET"])
    }

    @Test
    func subscriptionGetMissingFieldsFallsBackToPost() async throws {
        let registered = URLProtocol.registerClass(OpenCodeStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenCodeStubURLProtocol.self)
            }
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            if request.httpMethod?.uppercased() == "GET" {
                return Self.makeResponse(
                    url: url,
                    body: #"{"ok":true}"#,
                    statusCode: 200,
                    contentType: "application/json")
            }

            let body = """
            {
              "rollingUsage": { "usagePercent": 22, "resetInSec": 300 },
              "weeklyUsage": { "usagePercent": 44, "resetInSec": 3600 }
            }
            """
            return Self.makeResponse(
                url: url,
                body: body,
                statusCode: 200,
                contentType: "application/json")
        }

        let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123")

        #expect(snapshot.rollingUsagePercent == 22)
        #expect(snapshot.weeklyUsagePercent == 44)
        #expect(methods == ["GET", "POST"])
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

final class OpenCodeStubURLProtocol: URLProtocol {
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
