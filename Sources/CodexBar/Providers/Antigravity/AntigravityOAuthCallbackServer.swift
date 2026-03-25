import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OAuth Callback Server

/// Lightweight HTTP server that listens for the Google OAuth redirect,
/// exchanges the authorization code for tokens, and resolves the user email.
enum AntigravityOAuthCallbackServer {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    #if DEBUG
    @TaskLocal static var dataForRequestOverride: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    #endif

    private enum CallbackValidationOutcome {
        case success(code: String)
        case retryableFailure(message: String)
        case terminalFailure(message: String)
    }

    private struct PendingCallbackSuccess {
        let clientFD: Int32
        let code: String
    }

    private enum CallbackConnectionOutcome {
        case readyForExchange(PendingCallbackSuccess)
        case retryableFailure(message: String)
        case terminalFailure(message: String)
    }

    /// Start a local HTTP listener, wait for the OAuth callback, exchange tokens, and return.
    static func waitForCallback(
        port: UInt16,
        expectedState: String,
        timeout: TimeInterval) async throws -> AntigravityOAuthTokens
    {
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        // Create a socket listener
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw AntigravityOAuthError.authenticationFailed("Failed to create socket")
        }

        // Allow port reuse
        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverFD)
            throw AntigravityOAuthError.authenticationFailed("Failed to bind to port \(port)")
        }

        listen(serverFD, 1)

        self.log.info("OAuth callback server listening on port \(port)")

        let deadline = Date().addingTimeInterval(timeout)
        let pendingCallback: PendingCallbackSuccess = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                defer { close(serverFD) }

                while true {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else {
                        continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                            "Timed out waiting for Google login callback"))
                        return
                    }

                    var timeoutValue = Self.makeSocketTimeout(seconds: remaining)
                    setsockopt(
                        serverFD,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        &timeoutValue,
                        socklen_t(MemoryLayout<timeval>.size))

                    let clientFD = accept(serverFD, nil, nil)
                    guard clientFD >= 0 else {
                        continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                            "Timed out waiting for Google login callback"))
                        return
                    }

                    let outcome = Self.handleCallbackConnection(
                        clientFD: clientFD,
                        expectedState: expectedState)

                    switch outcome {
                    case let .readyForExchange(pending):
                        continuation.resume(returning: pending)
                        return
                    case let .terminalFailure(message):
                        continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(message))
                        return
                    case let .retryableFailure(message):
                        Self.log.warning("Ignoring retryable OAuth callback failure", metadata: ["reason": message])
                        continue
                    }
                }
            }
        }

        defer { close(pendingCallback.clientFD) }

        do {
            let tokens = try await self.exchangeCodeForTokens(code: pendingCallback.code, redirectURI: redirectURI)
            self.respond(to: pendingCallback.clientFD, with: .success(code: pendingCallback.code))

            // Email is optional, so don't block a successful login on this extra request.
            let email = try? await self.fetchUserEmail(accessToken: tokens.accessToken)

            return AntigravityOAuthTokens(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresAt,
                email: email,
                projectId: nil)
        } catch {
            self.respond(
                to: pendingCallback.clientFD,
                with: .terminalFailure(message: self.callbackFailureMessage(for: error)))
            throw error
        }
    }

    // MARK: - Token Exchange

    private static func exchangeCodeForTokens(
        code: String,
        redirectURI: String) async throws -> AntigravityOAuthTokens
    {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.httpBody = AntigravityOAuthFormEncoding.bodyData([
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: AntigravityOAuthConfig.clientId),
            URLQueryItem(name: "client_secret", value: AntigravityOAuthConfig.clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ])

        let (data, response) = try await self.data(for: request, timeout: 15)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            self.log.error("Token exchange failed", metadata: ["body": body])
            throw AntigravityOAuthError.authenticationFailed("Token exchange failed")
        }

        let decoded = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        return AntigravityOAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            email: nil,
            projectId: nil)
    }

    // MARK: - User Info

    private static func fetchUserEmail(accessToken: String) async throws -> String? {
        let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await self.data(for: request, timeout: 10)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["email"] as? String
    }

    private static func handleCallbackConnection(
        clientFD: Int32,
        expectedState: String) -> CallbackConnectionOutcome
    {
        self.suppressSIGPIPE(on: clientFD)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
        guard bytesRead > 0 else {
            close(clientFD)
            return .retryableFailure(message: "Empty callback request")
        }

        let request = String(bytes: buffer[..<bytesRead], encoding: .utf8) ?? ""
        let outcome = self.parseCallbackRequest(request, expectedState: expectedState)
        switch outcome {
        case let .success(code):
            return .readyForExchange(PendingCallbackSuccess(clientFD: clientFD, code: code))
        case .retryableFailure, .terminalFailure:
            self.respond(to: clientFD, with: outcome)
            close(clientFD)
            switch outcome {
            case let .retryableFailure(message):
                return .retryableFailure(message: message)
            case let .terminalFailure(message):
                return .terminalFailure(message: message)
            case .success:
                preconditionFailure("Unexpected success outcome")
            }
        }
    }

    private static func parseCallbackRequest(
        _ request: String,
        expectedState: String) -> CallbackValidationOutcome
    {
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let path = firstLine.components(separatedBy: " ").dropFirst().first,
              let urlComponents = URLComponents(string: "http://localhost\(path)"),
              let items = urlComponents.queryItems
        else {
            return .retryableFailure(message: "Invalid callback request")
        }

        let state = items.first(where: { $0.name == "state" })?.value
        let authCode = items.first(where: { $0.name == "code" })?.value

        guard state == expectedState else {
            return .retryableFailure(message: "State mismatch in OAuth callback")
        }

        if let authCode, !authCode.isEmpty {
            return .success(code: authCode)
        }

        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            return .terminalFailure(message: "OAuth error: \(error)")
        }

        return .retryableFailure(message: "Missing authorization code in OAuth callback")
    }

    private static func httpResponse(for outcome: CallbackValidationOutcome) -> String {
        let html = self.callbackHTML(for: outcome)
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
    }

    private static func respond(to clientFD: Int32, with outcome: CallbackValidationOutcome) {
        let responseData = Data(self.httpResponse(for: outcome).utf8)
        let errorCode = responseData.withUnsafeBytes { rawBuffer -> Int32? in
            guard let baseAddress = rawBuffer.baseAddress else {
                return nil
            }

            var totalBytesSent = 0
            while totalBytesSent < rawBuffer.count {
                let remainingBytes = rawBuffer.count - totalBytesSent
                let bytesSent = send(clientFD, baseAddress.advanced(by: totalBytesSent), remainingBytes, 0)
                if bytesSent < 0 {
                    return errno
                }
                if bytesSent == 0 {
                    return ECONNRESET
                }
                totalBytesSent += bytesSent
            }

            return nil
        }

        guard let errorCode else {
            return
        }

        switch errorCode {
        case EPIPE, ECONNRESET:
            self.log.info(
                "OAuth callback client disconnected before response was written",
                metadata: ["errno": "\(errorCode)"])
        default:
            self.log.warning(
                "Failed to write OAuth callback response",
                metadata: ["errno": "\(errorCode)"])
        }
    }

    private static func callbackHTML(for outcome: CallbackValidationOutcome) -> String {
        let rawTitle: String
        let rawMessage: String

        switch outcome {
        case .success:
            rawTitle = "✅ Signed in to CodexBar"
            rawMessage = "You can close this tab and return to CodexBar."
        case let .retryableFailure(reason), let .terminalFailure(reason):
            rawTitle = "CodexBar could not sign you in"
            rawMessage = "Return to CodexBar and try again. \(reason)"
        }

        let title = self.escapeHTML(rawTitle)
        let message = self.escapeHTML(rawMessage)

        return """
        <html><body style="font-family: -apple-system, sans-serif; display: flex; \
        justify-content: center; align-items: center; height: 100vh; margin: 0; \
        background: #1a1a2e; color: #e0e0e0;">
        <div style="text-align: center;">
        <h1>\(title)</h1>
        <p>\(message)</p>
        </div></body></html>
        """
    }

    private static func makeSocketTimeout(seconds: TimeInterval) -> timeval {
        let clampedSeconds = max(0, seconds)
        let wholeSeconds = floor(clampedSeconds)
        let fractional = clampedSeconds - wholeSeconds
        return timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32(fractional * 1_000_000))
    }

    private static func suppressSIGPIPE(on clientFD: Int32) {
        var noSIGPIPE: Int32 = 1
        let result = withUnsafePointer(to: &noSIGPIPE) { pointer in
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size))
        }
        guard result == 0 else {
            self.log.warning(
                "Failed to suppress SIGPIPE on OAuth callback socket",
                metadata: ["errno": "\(errno)"])
            return
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func callbackFailureMessage(for error: Error) -> String {
        switch error {
        case let AntigravityOAuthError.authenticationFailed(message),
             let AntigravityOAuthError.tokenRefreshFailed(message):
            message
        case let AntigravityOAuthError.keychainWriteFailed(status):
            "Keychain write failed (OSStatus: \(status))"
        default:
            error.localizedDescription
        }
    }

    private static func data(for request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        #if DEBUG
        if let override = self.dataForRequestOverride {
            return try await override(request)
        }
        #endif

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

// MARK: - Response Types

private struct TokenExchangeResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}
