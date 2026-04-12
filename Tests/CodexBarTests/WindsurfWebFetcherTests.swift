import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct WindsurfWebFetcherTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WindsurfWebFetcherStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test
    func `manual refresh token sends windsurf browser headers to firebase`() async throws {
        defer {
            WindsurfWebFetcherStubURLProtocol.requests = []
            WindsurfWebFetcherStubURLProtocol.handler = nil
        }

        WindsurfWebFetcherStubURLProtocol.requests = []
        WindsurfWebFetcherStubURLProtocol.handler = { request in
            let url = try #require(request.url)

            switch url.host {
            case "securetoken.googleapis.com":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://windsurf.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://windsurf.com/subscription/usage")

                let body = Self.requestBodyString(from: request)
                #expect(body == "grant_type=refresh_token&refresh_token=AMf-vB-refresh-token")

                return Self.makeResponse(
                    url: url,
                    body: #"{"access_token":"windsurf-access-token"}"#,
                    statusCode: 200)

            case "windsurf.com":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://windsurf.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://windsurf.com/subscription/usage")

                let bodyData = Data(Self.requestBodyString(from: request).utf8)
                let body = try #require(
                    JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                #expect(body["authToken"] as? String == "windsurf-access-token")
                #expect(body["includeTopUpStatus"] as? Bool == true)

                return Self.makeResponse(
                    url: url,
                    body: #"{"planStatus":{"planInfo":{"planName":"Pro"}}}"#,
                    statusCode: 200)

            default:
                Issue.record("Unexpected request host: \(url.host ?? "<missing>")")
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let snapshot = try await WindsurfWebFetcher.fetchUsage(
            browserDetection: BrowserDetection(cacheTTL: 0),
            cookieSource: .manual,
            manualAccessToken: " AMf-vB-refresh-token ",
            timeout: 2,
            session: self.makeSession())

        #expect(WindsurfWebFetcherStubURLProtocol.requests.count == 2)
        #expect(snapshot.identity?.providerID == .windsurf)
        #expect(snapshot.identity?.loginMethod == "Pro")
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func requestBodyString(from request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8) ?? ""
        }

        guard let stream = request.httpBodyStream else {
            return ""
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class WindsurfWebFetcherStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
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
