import AuthenticationServices
import CodexBariOSShared
import Foundation
import Network
import UIKit

@MainActor
final class BrowserLoginCoordinator: NSObject {
    private var currentSession: ASWebAuthenticationSession?

    func loginCodex() async throws -> CodexCredentials {
        let server = LoopbackCallbackServer(
            expectedPath: CodexOAuthClient.callbackPath,
            preferredPort: CodexOAuthClient.callbackPort)
        let redirectURI = try await server.start()
        let request = CodexOAuthClient.makeAuthorizationRequest(redirectURI: redirectURI)
        let callbackURL = try await self.runLoopbackAuthentication(
            startURL: request.url,
            callbackServer: server)
        return try await CodexOAuthClient.credentials(
            from: callbackURL,
            expectedState: request.state,
            redirectURI: redirectURI,
            codeVerifier: request.codeVerifier)
    }

    func loginClaude() async throws -> ClaudeCredentials {
        let redirectURI = ClaudeOAuthClient.redirectURI
        let request = ClaudeOAuthClient.makeAuthorizationRequest(redirectURI: redirectURI)
        let callbackURL = try await self.runBrowserAuthentication(
            startURL: request.url,
            callbackURLScheme: redirectURI.scheme)
        return try await ClaudeOAuthClient.credentials(
            from: callbackURL,
            expectedState: request.state,
            redirectURI: redirectURI,
            codeVerifier: request.codeVerifier)
    }

    private func runLoopbackAuthentication(
        startURL: URL,
        callbackServer: LoopbackCallbackServer) async throws -> URL
    {
        let callbackTask = Task {
            try await callbackServer.waitForCallbackURL()
        }
        defer {
            callbackTask.cancel()
            Task {
                await callbackServer.stop()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var observedCallback = false

            func finish(_ result: Result<URL, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            let session = ASWebAuthenticationSession(url: startURL, callbackURLScheme: nil) { callbackURL, error in
                Task { @MainActor in
                    self.currentSession = nil
                    if let callbackURL, !observedCallback {
                        finish(.success(callbackURL))
                    } else if let error, !observedCallback {
                        finish(.failure(error))
                    } else if !observedCallback {
                        finish(.failure(BrowserLoginCoordinatorError.invalidCallback))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.currentSession = session

            Task {
                do {
                    let callbackURL = try await callbackTask.value
                    await MainActor.run {
                        observedCallback = true
                        self.currentSession?.cancel()
                        self.currentSession = nil
                        finish(.success(callbackURL))
                    }
                } catch {
                    await MainActor.run {
                        self.currentSession?.cancel()
                        self.currentSession = nil
                        finish(.failure(error))
                    }
                }
            }

            guard session.start() else {
                self.currentSession = nil
                finish(.failure(BrowserLoginCoordinatorError.unableToStart))
                return
            }
        }
    }

    private func runBrowserAuthentication(
        startURL: URL,
        callbackURLScheme: String?) async throws -> URL
    {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false

            func finish(_ result: Result<URL, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            let session = ASWebAuthenticationSession(url: startURL, callbackURLScheme: callbackURLScheme) { callbackURL, error in
                Task { @MainActor in
                    self.currentSession = nil
                    if let callbackURL {
                        finish(.success(callbackURL))
                    } else if let error {
                        finish(.failure(error))
                    } else {
                        finish(.failure(BrowserLoginCoordinatorError.invalidCallback))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.currentSession = session

            guard session.start() else {
                self.currentSession = nil
                finish(.failure(BrowserLoginCoordinatorError.unableToStart))
                return
            }
        }
    }
}

extension BrowserLoginCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIWindow()
    }
}

private enum BrowserLoginCoordinatorError: LocalizedError {
    case unableToStart
    case invalidCallback

    var errorDescription: String? {
        switch self {
        case .unableToStart:
            return "Unable to start the browser login session."
        case .invalidCallback:
            return "The browser login callback was invalid."
        }
    }
}

private actor LoopbackCallbackServer {
    private let expectedPath: String
    private let preferredPort: UInt16?
    private let queue = DispatchQueue(label: "CodexBariOS.LoopbackCallbackServer")
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var startupContinuation: CheckedContinuation<URL, Error>?

    init(expectedPath: String, preferredPort: UInt16? = nil) {
        self.expectedPath = expectedPath
        self.preferredPort = preferredPort
    }

    func start() async throws -> URL {
        let port: NWEndpoint.Port
        if let preferredPort {
            guard let resolvedPort = NWEndpoint.Port(rawValue: preferredPort) else {
                throw BrowserLoginCoordinatorError.unableToStart
            }
            port = resolvedPort
        } else {
            port = .any
        }

        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak listener] connection in
            guard listener != nil else { return }
            Task {
                await self.handle(connection: connection)
            }
        }
        listener.stateUpdateHandler = { state in
            Task {
                await self.handle(state: state)
            }
        }
        listener.start(queue: self.queue)

        return try await withCheckedThrowingContinuation { continuation in
            self.startupContinuation = continuation
        }
    }

    func waitForCallbackURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.callbackContinuation = continuation
        }
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
        self.startupContinuation = nil
        self.callbackContinuation = nil
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            guard let listener = self.listener, let port = listener.port else {
                self.startupContinuation?.resume(throwing: BrowserLoginCoordinatorError.unableToStart)
                self.startupContinuation = nil
                return
            }
            let url = URL(string: "http://localhost:\(port.rawValue)\(self.expectedPath)")!
            self.startupContinuation?.resume(returning: url)
            self.startupContinuation = nil
        case let .failed(error):
            self.startupContinuation?.resume(throwing: error)
            self.startupContinuation = nil
            self.callbackContinuation?.resume(throwing: error)
            self.callbackContinuation = nil
            self.listener = nil
        case .cancelled:
            self.listener = nil
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: self.queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
            Task {
                await self.processRequest(
                    data: data,
                    error: error,
                    connection: connection)
            }
        }
    }

    private func processRequest(data: Data?, error: NWError?, connection: NWConnection) {
        defer {
            connection.cancel()
        }

        if let error {
            self.callbackContinuation?.resume(throwing: error)
            self.callbackContinuation = nil
            self.listener?.cancel()
            return
        }

        guard let data,
              let requestText = String(data: data, encoding: .utf8),
              let requestLine = requestText.split(separator: "\r\n").first
        else {
            self.sendHTMLResponse(statusCode: 400, title: "Bad Request", body: "Invalid callback.", on: connection)
            return
        }

        let segments = requestLine.split(separator: " ")
        guard segments.count >= 2 else {
            self.sendHTMLResponse(statusCode: 400, title: "Bad Request", body: "Invalid callback.", on: connection)
            return
        }

        let target = String(segments[1])
        guard let callbackURL = URL(string: "http://localhost\(target)"),
              callbackURL.path == self.expectedPath
        else {
            self.sendHTMLResponse(statusCode: 404, title: "Not Found", body: "Unknown callback path.", on: connection)
            return
        }

        self.sendHTMLResponse(
            statusCode: 200,
            title: "Sign-in complete",
            body: "You can close this window and return to CodexBar iOS.",
            on: connection)
        self.callbackContinuation?.resume(returning: callbackURL)
        self.callbackContinuation = nil
        self.listener?.cancel()
    }

    private func sendHTMLResponse(statusCode: Int, title: String, body: String, on connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(title)</title>
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px;">
          <h2>\(title)</h2>
          <p>\(body)</p>
        </body>
        </html>
        """
        let response = """
        HTTP/1.1 \(statusCode) OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
