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
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
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
                    case let .success(code):
                        continuation.resume(returning: code)
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

        // Exchange code for tokens
        let tokens = try await self.exchangeCodeForTokens(code: code, redirectURI: redirectURI)

        // Fetch user email
        let email = try? await self.fetchUserEmail(accessToken: tokens.accessToken)

        return AntigravityOAuthTokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            email: email,
            projectId: nil)
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
        expectedState: String) -> CallbackValidationOutcome
    {
        defer { close(clientFD) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
        guard bytesRead > 0 else {
            return .retryableFailure(message: "Empty callback request")
        }

        let request = String(bytes: buffer[..<bytesRead], encoding: .utf8) ?? ""
        let outcome = self.parseCallbackRequest(request, expectedState: expectedState)
        let response = self.httpResponse(for: outcome)
        _ = response.withCString { send(clientFD, $0, Int(strlen($0)), 0) }
        return outcome
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

    private static func callbackHTML(for outcome: CallbackValidationOutcome) -> String {
        let title: String
        let message: String

        switch outcome {
        case .success:
            title = "✅ Signed in to CodexBar"
            message = "You can close this tab and return to CodexBar."
        case let .retryableFailure(reason), let .terminalFailure(reason):
            title = "CodexBar could not sign you in"
            message = "Return to CodexBar and try again. \(reason)"
        }

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
