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

        // Wait for connection with timeout using DispatchSource or a simple polling approach
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global().async {
                // Set socket timeout
                var tv = timeval()
                tv.tv_sec = Int(timeout)
                setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let clientFD = accept(serverFD, nil, nil)
                guard clientFD >= 0 else {
                    close(serverFD)
                    continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                        "Timed out waiting for Google login callback"))
                    return
                }

                // Read the HTTP request
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = recv(clientFD, &buffer, buffer.count, 0)

                guard bytesRead > 0 else {
                    close(clientFD)
                    close(serverFD)
                    continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                        "Empty callback request"))
                    return
                }

                let request = String(bytes: buffer[..<bytesRead], encoding: .utf8) ?? ""

                // Send success response
                let html = """
                <html><body style="font-family: -apple-system, sans-serif; display: flex; \
                justify-content: center; align-items: center; height: 100vh; margin: 0; \
                background: #1a1a2e; color: #e0e0e0;">
                <div style="text-align: center;">
                <h1>✅ Signed in to CodexBar</h1>
                <p>You can close this tab and return to CodexBar.</p>
                </div></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
                _ = response.withCString { send(clientFD, $0, Int(strlen($0)), 0) }
                close(clientFD)
                close(serverFD)

                // Parse code and state from query string
                guard let firstLine = request.components(separatedBy: "\r\n").first,
                      let path = firstLine.components(separatedBy: " ").dropFirst().first,
                      let urlComponents = URLComponents(string: "http://localhost\(path)"),
                      let items = urlComponents.queryItems
                else {
                    continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                        "Invalid callback request"))
                    return
                }

                let state = items.first(where: { $0.name == "state" })?.value
                let authCode = items.first(where: { $0.name == "code" })?.value

                guard state == expectedState else {
                    continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                        "State mismatch in OAuth callback"))
                    return
                }

                guard let authCode else {
                    let error = items.first(where: { $0.name == "error" })?.value ?? "unknown"
                    continuation.resume(throwing: AntigravityOAuthError.authenticationFailed(
                        "OAuth error: \(error)"))
                    return
                }

                continuation.resume(returning: authCode)
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

        let params = [
            "code=\(code)",
            "client_id=\(AntigravityOAuthConfig.clientId)",
            "client_secret=\(AntigravityOAuthConfig.clientSecret)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code",
        ].joined(separator: "&")
        request.httpBody = params.data(using: .utf8)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
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

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["email"] as? String
    }
}

// MARK: - Response Types

private struct TokenExchangeResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}
