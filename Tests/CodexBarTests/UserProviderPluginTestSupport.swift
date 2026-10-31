#if canImport(JavaScriptCore)
import AppKit
import Foundation
import Testing
@testable import CodexBarCore

extension UserProviderPluginTests {
    final class RecordingTransport: ProviderHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let responseJSON: String
        private let responseHeaders: [String: String]
        private var requests: [URLRequest] = []

        init(responseJSON: String, responseHeaders: [String: String] = ["Content-Type": "application/json"]) {
            self.responseJSON = responseJSON
            self.responseHeaders = responseHeaders
        }

        var requestCount: Int {
            self.lock.withLock { self.requests.count }
        }

        var lastRequest: URLRequest? {
            self.lock.withLock { self.requests.last }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.lock.withLock { self.requests.append(request) }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: self.responseHeaders)!
            return (Data(self.responseJSON.utf8), response)
        }
    }

    actor ResolverAccess {
        private(set) var calls = 0

        func record(provider _: UsageProvider, domain _: String) {
            self.calls += 1
        }
    }

    actor RetryDelayRecorder {
        private(set) var values: [TimeInterval] = []

        func record(_ seconds: TimeInterval) {
            self.values.append(seconds)
        }
    }

    actor SequenceResponseTransport: ProviderHTTPTransport {
        private var responses: [(status: Int, body: String, headers: [String: String])]
        private(set) var requestCount = 0

        init(responses: [(Int, String, [String: String])]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.requestCount += 1
            let response = self.responses.removeFirst()
            var headers = response.headers
            headers["Content-Type"] = "application/json"
            let httpResponse = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: response.status,
                httpVersion: nil,
                headerFields: headers)!
            return (Data(response.body.utf8), httpResponse)
        }
    }

    @MainActor
    final class PluginMenuProofCanvas: NSView {
        override var isFlipped: Bool {
            true
        }

        override var fittingSize: NSSize {
            self.frame.size
        }
    }

    struct Fixture {
        let root: URL
        let providers: URL
        let cache: URL
        let history: URL
        let approvals: ProviderPluginApprovalStore

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("UserProviderPluginTests-\(UUID().uuidString)", isDirectory: true)
            self.providers = self.root.appendingPathComponent("providers", isDirectory: true)
            self.cache = self.root.appendingPathComponent("cache", isDirectory: true)
            self.history = self.root.appendingPathComponent("history", isDirectory: true)
            self.approvals = ProviderPluginApprovalStore(fileURL: self.root.appendingPathComponent("approvals.json"))
            try FileManager.default.createDirectory(at: self.providers, withIntermediateDirectories: true)
        }

        func write(name: String, source: String) throws -> URL {
            let url = self.providers.appendingPathComponent(name)
            try Data(source.utf8).write(to: url, options: .atomic)
            return url
        }

        func loader(transport: any ProviderHTTPTransport) -> UserProviderPluginLoader {
            UserProviderPluginLoader(
                providersDirectory: self.providers,
                cacheDirectory: self.cache,
                transport: transport)
        }

        func remove() {
            UserProviderPluginRegistry.refresh(loader: UserProviderPluginLoader(
                providersDirectory: self.root.appendingPathComponent("empty"),
                cacheDirectory: self.cache))
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
#endif
