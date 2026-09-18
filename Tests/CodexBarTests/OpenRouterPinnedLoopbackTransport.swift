import Foundation
import Security
import Testing
@testable import CodexBarCore

/// Test-only transport for an ephemeral loopback HTTPS fixture. It has no fallback to system trust.
final class OpenRouterPinnedLoopbackTransport: NSObject, ProviderHTTPTransport, @unchecked Sendable {
    private let port: Int
    private let session: URLSession
    private let diagnostics: OpenRouterPinnedLoopbackDiagnostics

    init(certificateDER: Data, port: Int) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw URLError(.cannotParseResponse)
        }
        self.port = port
        let diagnostics = OpenRouterPinnedLoopbackDiagnostics()
        self.diagnostics = diagnostics
        let delegate = OpenRouterPinnedLoopbackTrustDelegate(
            certificate: certificate,
            port: port,
            diagnostics: diagnostics)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        // A loopback proof must not follow a runner's default proxy settings.
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    deinit {
        self.session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              url.host == "127.0.0.1",
              url.port == self.port
        else {
            self.diagnostics.record("rejected request outside pinned origin")
            throw URLError(.unsupportedURL)
        }
        self.diagnostics.record("request \(request.httpMethod ?? "GET") \(url.path)")
        do {
            let response = try await self.session.data(for: request)
            self.diagnostics.record("response received")
            return response
        } catch {
            self.diagnostics.record("session error: \(Self.describe(error))")
            throw error
        }
    }

    func writeDiagnostics(to directory: URL) throws {
        try self.diagnostics.write(to: directory.appendingPathComponent("loopback-transport-diagnostics.json"))
    }

    private let delegate: OpenRouterPinnedLoopbackTrustDelegate

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }
}

private class OpenRouterLoopbackRedirectRejectionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

private final class OpenRouterPinnedLoopbackTrustDelegate: OpenRouterLoopbackRedirectRejectionDelegate,
    @unchecked Sendable
{
    private let certificate: SecCertificate
    private let port: Int
    private let diagnostics: OpenRouterPinnedLoopbackDiagnostics

    init(certificate: SecCertificate, port: Int, diagnostics: OpenRouterPinnedLoopbackDiagnostics) {
        self.certificate = certificate
        self.port = port
        self.diagnostics = diagnostics
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let protectionSpace = challenge.protectionSpace
        self.diagnostics.record(
            "challenge method=\(protectionSpace.authenticationMethod) host=\(protectionSpace.host) " +
                "port=\(protectionSpace.port) previousFailures=\(challenge.previousFailureCount)")
        guard protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              protectionSpace.host == "127.0.0.1",
              protectionSpace.port == self.port,
              let trust = protectionSpace.serverTrust
        else {
            self.diagnostics.record("challenge rejected before trust evaluation")
            return (.cancelAuthenticationChallenge, nil)
        }
        let anchorStatus = SecTrustSetAnchorCertificates(trust, [self.certificate] as CFArray)
        let anchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard anchorStatus == errSecSuccess, anchorsOnlyStatus == errSecSuccess else {
            self.diagnostics.record("trust anchor status=\(anchorStatus) anchorsOnly=\(anchorsOnlyStatus)")
            return (.cancelAuthenticationChallenge, nil)
        }

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            self.diagnostics.record("trust evaluation failed code=\(error.map(CFErrorGetCode) ?? 0)")
            return (.cancelAuthenticationChallenge, nil)
        }
        self.diagnostics.record("trust evaluation succeeded")
        return (.useCredential, URLCredential(trust: trust))
    }
}

private final class OpenRouterPinnedLoopbackDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        self.lock.lock()
        self.events.append(event)
        self.lock.unlock()
    }

    func write(to url: URL) throws {
        self.lock.lock()
        let snapshot = self.events
        self.lock.unlock()
        let data = try JSONSerialization.data(
            withJSONObject: ["events": snapshot],
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

struct OpenRouterPinnedLoopbackRedirectTests {
    @Test(arguments: [
        "http://127.0.0.1:12345/api/v1/key",
        "https://example.invalid/api/v1/key",
        "https://127.0.0.1:12346/api/v1/key",
        "https://127.0.0.1:12345/api/v1/key",
    ])
    func `proof transport rejects redirects before sending another request`(_ destination: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://127.0.0.1:12345/api/v1/credits"))
        let response = try #require(HTTPURLResponse(
            url: origin, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination]))
        let request = try URLRequest(url: #require(URL(string: destination)))
        let task = session.dataTask(with: origin)
        let delegate = OpenRouterLoopbackRedirectRejectionDelegate()
        let redirectedRequest: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: { continuation.resume(returning: $0) })
        }
        #expect(redirectedRequest == nil)
    }
}
