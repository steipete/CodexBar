import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AppKit
#endif

public actor AntigravityOAuthFlow {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)
    private static let httpTimeout: TimeInterval = 15.0

    private var callbackServer: CallbackServer?
    private var pendingState: String?
    private var pendingContinuation: CheckedContinuation<String, Error>?

    public init() {}

    public func startAuthorization() async throws -> AntigravityOAuthCredentials {
        Self.log.debug("Starting OAuth authorization flow")

        let port = try await self.startCallbackServer()
        let redirectUri = "http://\(AntigravityOAuthConfig.callbackHost):\(port)"
        let state = self.generateState()
        self.pendingState = state

        let authURL = self.buildAuthURL(redirectUri: redirectUri, state: state)

        Self.log.debug("Requesting scopes: \(AntigravityOAuthConfig.scopes.joined(separator: ", "))")
        Self.log.debug("Using access_type=offline and prompt=consent to ensure refresh token")
        Self.log.info("Opening Antigravity OAuth authorization URL")
        #if os(macOS)
        if let url = URL(string: authURL) {
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
        #endif

        let code = try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
        }

        return try await self.exchangeCodeForToken(code: code, redirectUri: redirectUri)
    }

    public func cancelAuthorization() {
        self.pendingContinuation?.resume(throwing: CancellationError())
        self.pendingContinuation = nil
        self.pendingState = nil
        self.stopCallbackServer()
    }

    private func startCallbackServer() async throws -> Int {
        var port = AntigravityOAuthConfig.callbackPortStart
        var attempts = 0

        while attempts < AntigravityOAuthConfig.callbackPortRange {
            do {
                let server = try CallbackServer(port: port) { code, state in
                    Task { [weak self] in
                        await self?.handleCallback(code: code, state: state)
                    }
                }
                self.callbackServer = server
                Self.log.info("Antigravity OAuth callback server started on port \(port)")
                return port
            } catch {
                port += 1
                attempts += 1
            }
        }

        throw AntigravityOAuthCredentialsError.networkError("No available port for OAuth callback")
    }

    private func stopCallbackServer() {
        self.callbackServer?.stop()
        self.callbackServer = nil
    }

    private func handleCallback(code: String?, state: String?) {
        defer {
            self.stopCallbackServer()
        }

        guard let code, let state else {
            self.pendingContinuation?
                .resume(throwing: AntigravityOAuthCredentialsError.decodeFailed("Missing code or state in callback"))
            self.pendingContinuation = nil
            return
        }

        guard state == self.pendingState else {
            self.pendingContinuation?.resume(throwing: AntigravityOAuthCredentialsError.decodeFailed("State mismatch"))
            self.pendingContinuation = nil
            return
        }

        self.pendingContinuation?.resume(returning: code)
        self.pendingContinuation = nil
        self.pendingState = nil
    }

    private func generateState() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<32).map { _ in chars.randomElement()! })
    }

    private func buildAuthURL(redirectUri: String, state: String) -> String {
        var components = URLComponents(string: AntigravityOAuthConfig.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AntigravityOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AntigravityOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        return components.url!.absoluteString
    }

    private func exchangeCodeForToken(code: String, redirectUri: String) async throws -> AntigravityOAuthCredentials {
        let params = [
            "client_id": AntigravityOAuthConfig.clientID,
            "client_secret": AntigravityOAuthConfig.clientSecret,
            "code": code,
            "redirect_uri": redirectUri,
            "grant_type": "authorization_code",
        ]

        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = URL(string: AntigravityOAuthConfig.tokenURL) else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.httpTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityOAuthCredentialsError
                .refreshFailed("Token exchange failed: HTTP \(statusCode) - \(errorBody)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid token exchange response")
        }

        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(expiresIn))
        let email = try? await AntigravityTokenRefresher.fetchUserEmail(accessToken: accessToken)

        Self.log.debug("Received OAuth response - access_token length: \(accessToken.count)")
        Self.log.debug("Received OAuth response - refresh_token length: \(refreshToken.count)")
        Self.log.debug("Token expires in: \(expiresIn) seconds")
        if let email {
            Self.log.debug("Resolved account email: \(email)")
        }

        Self.log.info("Antigravity OAuth authorization successful", metadata: [
            "email": email ?? "unknown",
        ])

        return AntigravityOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            email: email,
            scopes: AntigravityOAuthConfig.scopes)
    }
}

private final class CallbackServer: @unchecked Sendable {
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let callback: @Sendable (String?, String?) -> Void
    private let queue = DispatchQueue(label: "com.codexbar.antigravity.oauth.callback")

    init(port: Int, callback: @escaping @Sendable (String?, String?) -> Void) throws {
        self.callback = callback
        try self.start(port: port)
    }

    private func start(port: Int) throws {
        #if os(Linux)
        self.serverSocket = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        self.serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard self.serverSocket >= 0 else {
            throw AntigravityOAuthCredentialsError.networkError("Failed to create socket")
        }

        var opt: Int32 = 1
        setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(self.serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else {
            close(self.serverSocket)
            throw AntigravityOAuthCredentialsError.networkError("Failed to bind to port \(port)")
        }

        guard listen(self.serverSocket, 1) >= 0 else {
            close(self.serverSocket)
            throw AntigravityOAuthCredentialsError.networkError("Failed to listen on port \(port)")
        }

        self.isRunning = true
        self.queue.async { [weak self] in
            self?.acceptConnections()
        }
    }

    func stop() {
        self.isRunning = false
        if self.serverSocket >= 0 {
            close(self.serverSocket)
            self.serverSocket = -1
        }
    }

    private func acceptConnections() {
        while self.isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(self.serverSocket, sockPtr, &addrLen)
                }
            }

            guard clientSocket >= 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)

            if bytesRead > 0 {
                let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                let (code, state) = self.parseOAuthCallback(request: request)

                let responseHTML = if code != nil {
                    """
                    <html>
                    <head><title>Authorization Successful</title></head>
                    <body style="font-family: system-ui; text-align: center; padding: 50px;">
                        <h1>Authorization Successful!</h1>
                        <p>You can close this window and return to CodexBar.</p>
                        <script>setTimeout(() => window.close(), 2000);</script>
                    </body>
                    </html>
                    """
                } else {
                    """
                    <html>
                    <head><title>Authorization Failed</title></head>
                    <body style="font-family: system-ui; text-align: center; padding: 50px;">
                        <h1>Authorization Failed</h1>
                        <p>Please close this window and try again.</p>
                    </body>
                    </html>
                    """
                }

                let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
                let response = headers + responseHTML
                _ = response.withCString { ptr in
                    send(clientSocket, ptr, strlen(ptr), 0)
                }

                close(clientSocket)
                self.callback(code, state)
                break
            }

            close(clientSocket)
        }
    }

    private func parseOAuthCallback(request: String) -> (code: String?, state: String?) {
        guard let firstLine = request.split(separator: "\r\n").first else { return (nil, nil) }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return (nil, nil) }

        let path = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(path)") else { return (nil, nil) }

        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value

        return (code, state)
    }
}
