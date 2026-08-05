import Foundation
import Testing
@testable import CodexBarCore

private final class OptionalZenBalanceTimeoutRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(value)
    }

    var values: [Value] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}

struct OpenCodeGoOptionalZenBalanceTimeoutTests {
    @Test
    func `optional zen balance caps workspace and balance request timeouts`() async throws {
        defer {
            OptionalZenBalanceTimeoutURLProtocol.handler = nil
        }

        let timeouts = OptionalZenBalanceTimeoutRecorder<TimeInterval>()
        OptionalZenBalanceTimeoutURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            timeouts.append(request.timeoutInterval)
            if url.path == "/_server" {
                return Self.makeResponse(
                    url: url,
                    body: #"{"workspaces":[{"id":"wrk_TEST123"}]}"#,
                    contentType: "application/json")
            }
            #expect(url.path == "/workspace/wrk_TEST123")
            return Self.makeResponse(
                url: url,
                body: #"<html><body><h2>Current balance $98.76</h2></body></html>"#,
                contentType: "text/html")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OptionalZenBalanceTimeoutURLProtocol.self]
        let balance = try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
            cookieHeader: "auth=test",
            timeout: 60,
            session: URLSession(configuration: configuration))

        #expect(balance == 98.76)
        #expect(timeouts.values == [5, 5])
    }

    private static func makeResponse(
        url: URL,
        body: String,
        contentType: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, Data(body.utf8))
    }
}

private final class OptionalZenBalanceTimeoutURLProtocol: URLProtocol {
    private static let handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.handlerBox.value }
        set { Self.handlerBox.setValue(newValue) }
    }

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
