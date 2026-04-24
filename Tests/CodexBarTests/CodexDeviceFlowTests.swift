@testable import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct CodexDeviceFlowTests {
    // MARK: - decodeInterval

    @Test
    func `decodeInterval accepts Int and clamps to five`() {
        #expect(CodexDeviceFlow.decodeInterval(10) == 10)
        #expect(CodexDeviceFlow.decodeInterval(2) == 5)
        #expect(CodexDeviceFlow.decodeInterval(5) == 5)
    }

    @Test
    func `decodeInterval accepts Double string and bogus values`() {
        #expect(CodexDeviceFlow.decodeInterval(7.0 as Double) == 7)
        #expect(CodexDeviceFlow.decodeInterval("8") == 8)
        #expect(CodexDeviceFlow.decodeInterval("4") == 5)
        #expect(CodexDeviceFlow.decodeInterval("9.5") == 9)
        #expect(CodexDeviceFlow.decodeInterval("not-a-number") == 5)
        #expect(CodexDeviceFlow.decodeInterval(nil) == 5)
    }

    // MARK: - extractChatGPTAccountID

    @Test
    func `extractChatGPTAccountID finds top-level claim in id token`() {
        let token = Self.makeJWT(payload: ["chatgpt_account_id": "acc-top"])
        #expect(
            CodexDeviceFlow.extractChatGPTAccountID(idToken: token, accessToken: "unused")
                == "acc-top")
    }

    @Test
    func `extractChatGPTAccountID finds nested openai auth claim`() {
        let token = Self.makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acc-nested"],
        ])
        #expect(
            CodexDeviceFlow.extractChatGPTAccountID(idToken: token, accessToken: "unused")
                == "acc-nested")
    }

    @Test
    func `extractChatGPTAccountID falls back to access token when id token missing claim`() {
        let idToken = Self.makeJWT(payload: ["sub": "someone"])
        let accessToken = Self.makeJWT(payload: ["chatgpt_account_id": "acc-access"])
        #expect(
            CodexDeviceFlow.extractChatGPTAccountID(idToken: idToken, accessToken: accessToken)
                == "acc-access")
    }

    @Test
    func `extractChatGPTAccountID returns nil when absent everywhere`() {
        let idToken = Self.makeJWT(payload: ["sub": "nobody"])
        let accessToken = Self.makeJWT(payload: ["sub": "nobody"])
        #expect(
            CodexDeviceFlow.extractChatGPTAccountID(idToken: idToken, accessToken: accessToken) == nil)
    }

    // MARK: - verification URL

    @Test
    func `verificationURL encodes user code and points at codex device page`() throws {
        let url = CodexDeviceFlow.verificationURL(userCode: "ABCD-EFGH")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "auth.openai.com")
        #expect(components.path == "/codex/device")
        #expect(components.queryItems?.first { $0.name == "user_code" }?.value == "ABCD-EFGH")
    }

    @Test
    func `verificationURL percent encodes user codes with reserved characters`() throws {
        let url = CodexDeviceFlow.verificationURL(userCode: "A B/C+D")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "user_code" }?.value == "A B/C+D")
        // The raw URL must contain proper percent-encoding for reserved characters.
        let raw = url.absoluteString
        #expect(raw.contains("user_code="))
        #expect(raw.contains(" ") == false)
    }

    // MARK: - pollForTokens end-to-end (URLProtocol stubbed)

    @Test
    func `pollForTokens returns credentials after 403 then 200 then token exchange`() async throws {
        defer {
            CodexDeviceFlowStubURLProtocol.reset()
        }

        let idToken = Self.makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acc-123"],
        ])
        let tokenResponseBody = """
        {
          "access_token": "access-xyz",
          "refresh_token": "refresh-xyz",
          "id_token": "\(idToken)",
          "expires_in": 3600
        }
        """
        let pollResponseBody = """
        {
          "authorization_code": "auth-code-abc",
          "code_verifier": "verifier-def"
        }
        """

        let pollCallCounter = PollCounter()
        CodexDeviceFlowStubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/accounts/deviceauth/token":
                let call = pollCallCounter.increment()
                if call == 1 {
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 403,
                        httpVersion: nil,
                        headerFields: nil)!
                    return (response, Data())
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data(pollResponseBody.utf8))
            case "/oauth/token":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data(tokenResponseBody.utf8))
            default:
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil)!
                return (response, Data())
            }
        }

        let flow = CodexDeviceFlow(urlSession: Self.stubbedSession())
        let credentials = try await flow.pollForTokens(
            deviceAuthID: "device-auth-id",
            userCode: "ABCD-EFGH",
            intervalSeconds: 5,
            // Ample deadline; the 5s clamp means we wait at least 5s per iteration so
            // set a deadline that's comfortably beyond two iterations.
            deadline: Date().addingTimeInterval(60))

        #expect(credentials.accessToken == "access-xyz")
        #expect(credentials.refreshToken == "refresh-xyz")
        #expect(credentials.idToken == idToken)
        #expect(credentials.accountId == "acc-123")
        #expect(pollCallCounter.value == 2)

        // The token-exchange request must be form-encoded, not JSON.
        let exchangeRequest = try #require(
            CodexDeviceFlowStubURLProtocol.requests.first { $0.url?.path == "/oauth/token" })
        #expect(
            exchangeRequest.value(forHTTPHeaderField: "Content-Type") ==
                "application/x-www-form-urlencoded")
    }

    @Test
    func `pollForTokens times out when deadline is already past`() async throws {
        defer {
            CodexDeviceFlowStubURLProtocol.reset()
        }

        CodexDeviceFlowStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil)!
            return (response, Data())
        }

        let flow = CodexDeviceFlow(urlSession: Self.stubbedSession())
        var caught: Swift.Error?
        do {
            _ = try await flow.pollForTokens(
                deviceAuthID: "device-auth-id",
                userCode: "ABCD-EFGH",
                intervalSeconds: 5,
                deadline: Date().addingTimeInterval(-1))
        } catch {
            caught = error
        }
        #expect((caught as? CodexDeviceFlow.Error) == .timedOut)
    }

    @Test
    func `pollForTokens surfaces cancellation`() async throws {
        defer {
            CodexDeviceFlowStubURLProtocol.reset()
        }

        CodexDeviceFlowStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil)!
            return (response, Data())
        }

        let flow = CodexDeviceFlow(urlSession: Self.stubbedSession())
        let task = Task {
            try await flow.pollForTokens(
                deviceAuthID: "device-auth-id",
                userCode: "ABCD-EFGH",
                intervalSeconds: 5,
                deadline: Date().addingTimeInterval(60))
        }

        // Give the task a moment to enter its first sleep, then cancel.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    // MARK: - helpers

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexDeviceFlowStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeJWT(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let signature = Data("sig".utf8)
        return [header, payloadData, signature]
            .map { Self.base64URLEncode($0) }
            .joined(separator: ".")
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Thread-safe call counter so the stub handler (which may be invoked from a
/// URLSession delegate queue) can mutate state without tripping Sendable diagnostics.
private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self._value += 1
        return self._value
    }

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._value
    }
}

final class CodexDeviceFlowStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        self.requests = []
        self.handler = nil
    }

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
