import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct CodexOpenAIWorkspaceResolverTests {
    @Test
    func `resolver returns workspace identity and sends expected headers`() async throws {
        defer {
            CodexOpenAIWorkspaceStubURLProtocol.handler = nil
            CodexOpenAIWorkspaceStubURLProtocol.requests = []
        }
        CodexOpenAIWorkspaceStubURLProtocol.requests = []

        CodexOpenAIWorkspaceStubURLProtocol.handler = { request in
            let requestURL = try #require(request.url)
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            let data = Data("""
            {
              "items": [
                { "id": "account-live", "name": "Team Alpha" }
              ]
            }
            """.utf8)
            return (response, data)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexOpenAIWorkspaceStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: " account-live ",
            lastRefresh: nil)

        let identity = try await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials, session: session)

        #expect(identity == CodexOpenAIWorkspaceIdentity(
            workspaceAccountID: "account-live",
            workspaceLabel: "Team Alpha"))
        #expect(CodexOpenAIWorkspaceStubURLProtocol.requests.count == 1)
        #expect(CodexOpenAIWorkspaceStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization")
            == "Bearer access-token")
        #expect(CodexOpenAIWorkspaceStubURLProtocol.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id")
            == "account-live")
        #expect(CodexOpenAIWorkspaceStubURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent")
            == "codex-cli")
    }

    @Test
    func `resolver returns personal when account name is empty`() async throws {
        defer {
            CodexOpenAIWorkspaceStubURLProtocol.handler = nil
            CodexOpenAIWorkspaceStubURLProtocol.requests = []
        }
        CodexOpenAIWorkspaceStubURLProtocol.requests = []

        CodexOpenAIWorkspaceStubURLProtocol.handler = { request in
            let requestURL = try #require(request.url)
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            let data = Data("""
            {
              "items": [
                { "id": "account-live", "name": "   " }
              ]
            }
            """.utf8)
            return (response, data)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexOpenAIWorkspaceStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: "account-live",
            lastRefresh: nil)

        let identity = try await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials, session: session)

        #expect(identity?.workspaceLabel == "Personal")
    }

    @Test
    func `workspace identity cache persists and normalizes workspace ids`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("codex-openai-workspaces.json")

        try CodexOpenAIWorkspaceIdentityCache.withFileURLOverrideForTesting(fileURL) {
            let cache = CodexOpenAIWorkspaceIdentityCache()
            try cache.store(CodexOpenAIWorkspaceIdentity(
                workspaceAccountID: " Account-Live ",
                workspaceLabel: "Team Alpha"))

            #expect(cache.workspaceLabel(for: "account-live") == "Team Alpha")
            #expect(cache.workspaceLabel(for: " ACCOUNT-LIVE ") == "Team Alpha")
        }
    }
}

final class CodexOpenAIWorkspaceStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
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
