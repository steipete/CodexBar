import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct OllamaUsageFetcherRetryMappingTests {
    @Test
    func `api key reader trims configured environment key`() {
        let token = OllamaAPISettingsReader.apiKey(environment: ["OLLAMA_API_KEY": " 'ollama-test' "])

        #expect(token == "ollama-test")
    }

    @Test
    func `api tags response maps to API key identity`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try OllamaAPIUsageFetcher._parseTagsForTesting(
            Data(#"{"models":[{"name":"gpt-oss:120b"}]}"#.utf8),
            now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.modelCount == 1)
        #expect(usage.primary == nil)
        #expect(usage.identity?.providerID == .ollama)
        #expect(usage.identity?.loginMethod == "API key")
        #expect(usage.updatedAt == now)
    }

    @Test
    func `api fetch sends bearer token and rejects unauthorized key`() async throws {
        let url = try #require(URL(string: "https://ollama.com/api/tags"))
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url == url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-test")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        do {
            _ = try await OllamaAPIUsageFetcher.fetchUsage(apiKey: "ollama-test", transport: transport)
            Issue.record("Expected unauthorized API error")
        } catch let error as OllamaUsageError {
            guard case .apiUnauthorized = error else {
                Issue.record("Expected apiUnauthorized, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected OllamaUsageError.apiUnauthorized, got \(error)")
        }
    }

    @Test
    func `missing usage shape surfaces public parse failed message`() async {
        defer { OllamaRetryMappingStubURLProtocol.handler = nil }

        OllamaRetryMappingStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = "<html><body>No usage data rendered.</body></html>"
            return Self.makeResponse(url: url, body: body, statusCode: 200)
        }

        let fetcher = OllamaUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            makeURLSession: { delegate in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [OllamaRetryMappingStubURLProtocol.self]
                return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            })
        do {
            _ = try await fetcher.fetch(
                cookieHeaderOverride: "session=test-cookie",
                manualCookieMode: true)
            Issue.record("Expected OllamaUsageError.parseFailed")
        } catch let error as OllamaUsageError {
            guard case let .parseFailed(message) = error else {
                Issue.record("Expected parseFailed, got \(error)")
                return
            }
            #expect(message == "Missing Ollama usage data.")
        } catch {
            Issue.record("Expected OllamaUsageError.parseFailed, got \(error)")
        }
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
            headerFields: ["Content-Type": "text/html"])!
        return (response, Data(body.utf8))
    }
}

final class OllamaRetryMappingStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host == "ollama.com" || host == "www.ollama.com"
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
