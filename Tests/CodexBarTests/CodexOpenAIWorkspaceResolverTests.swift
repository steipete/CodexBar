import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexOpenAIWorkspaceResolverTests {
    @Test
    func `resolver returns selected team workspace from accounts endpoint`() async throws {
        let session = URLSession(configuration: ResolverURLProtocol.configuration(jsonObject: [
            "items": [
                ["id": "team-123", "name": "IDconcepts"],
                ["id": "personal-456", "name": NSNull()],
            ],
        ]))
        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: "TEAM-123",
            lastRefresh: nil)

        let resolved = try await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials, session: session)

        #expect(resolved?.workspaceAccountID == "team-123")
        #expect(resolved?.workspaceLabel == "IDconcepts")
        #expect(ResolverURLProtocol.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "team-123")
    }

    @Test
    func `resolver maps unnamed selected account to personal`() async throws {
        let session = URLSession(configuration: ResolverURLProtocol.configuration(jsonObject: [
            "items": [
                ["id": "personal-456", "name": NSNull()],
            ],
        ]))
        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: "personal-456",
            lastRefresh: nil)

        let resolved = try await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials, session: session)

        #expect(resolved?.workspaceAccountID == "personal-456")
        #expect(resolved?.workspaceLabel == "Personal")
    }
}

private class ResolverURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responseBody = Data()
    private nonisolated(unsafe) static var responseStatusCode = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func configuration(jsonObject: Any, statusCode: Int = 200) -> URLSessionConfiguration {
        self.lock.lock()
        self.responseBody = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data()
        self.responseStatusCode = statusCode
        self.lastRequest = nil
        self.lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = self.request
        let body = Self.responseBody
        let statusCode = Self.responseStatusCode
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
