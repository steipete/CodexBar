import AppKit
import CodexBarCore
import Darwin
import Foundation
import Network

enum AntigravityLoginRunner {
    enum Phase {
        case waitingBrowser
    }

    struct Result {
        enum Outcome {
            case success(String?)
            case cancelled
            case timedOut
            case launchFailed(String)
            case failed(String)
        }

        let outcome: Outcome
    }

    static func run(
        timeout: TimeInterval = 120,
        onPhaseChange: (@Sendable (Phase) -> Void)? = nil,
        onCredentialsCreated: (@Sendable () -> Void)? = nil) async -> Result
    {
        guard let oauthClient = AntigravityOAuthConfig.resolvedClient() else {
            return Result(outcome: .failed(AntigravityOAuthConfig.missingCredentialsMessage))
        }

        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = AntigravityLoopbackServer(state: state)

        do {
            let callbackURL = try await server.start()
            let authURL = try Self.makeAuthorizationURL(
                redirectURL: callbackURL,
                state: state,
                oauthClient: oauthClient)
            onPhaseChange?(.waitingBrowser)

            let opened = await MainActor.run {
                NSWorkspace.shared.open(authURL)
            }
            guard opened else {
                server.stop()
                return Result(outcome: .launchFailed(authURL.absoluteString))
            }

            let callback = try await withThrowingTaskGroup(of: AntigravityOAuthCallback.self) { group in
                group.addTask {
                    try await server.waitForCallback()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    server.cancelCallbackWait(with: AntigravityLoginError.timedOut)
                    throw AntigravityLoginError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next().unsafelyUnwrapped
            }
            server.stop()

            if let error = callback.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                if error == "access_denied" {
                    return Result(outcome: .cancelled)
                }
                return Result(outcome: .failed(error))
            }

            guard callback.returnedState == state else {
                return Result(outcome: .failed("Google login state mismatch."))
            }
            guard let code = callback.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                return Result(outcome: .failed("Google login did not return an authorization code."))
            }

            let tokenResponse = try await Self.exchangeCodeForTokens(
                code: code,
                redirectURL: callbackURL,
                oauthClient: oauthClient)
            let email = try await Self.fetchUserEmail(accessToken: tokenResponse.accessToken)
            let credentials = AntigravityOAuthCredentials(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiryDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
                idToken: tokenResponse.idToken,
                email: email,
                projectID: nil,
                clientID: oauthClient.clientID,
                clientSecret: oauthClient.clientSecret)
            try AntigravityOAuthCredentialsStore().save(credentials)
            onCredentialsCreated?()
            return Result(outcome: .success(email))
        } catch is CancellationError {
            server.stop()
            return Result(outcome: .cancelled)
        } catch AntigravityLoginError.timedOut {
            server.stop()
            return Result(outcome: .timedOut)
        } catch let AntigravityLoginError.launchFailed(message) {
            server.stop()
            return Result(outcome: .launchFailed(message))
        } catch {
            server.stop()
            return Result(outcome: .failed(error.localizedDescription))
        }
    }

    private static func makeAuthorizationURL(
        redirectURL: URL,
        state: String,
        oauthClient: AntigravityOAuthClient) throws -> URL
    {
        guard var components = URLComponents(url: AntigravityOAuthConfig.authURL, resolvingAgainstBaseURL: false) else {
            throw AntigravityLoginError.invalidAuthorizationURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: oauthClient.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AntigravityOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw AntigravityLoginError.invalidAuthorizationURL
        }
        return url
    }

    private static func exchangeCodeForTokens(
        code: String,
        redirectURL: URL,
        oauthClient: AntigravityOAuthClient) async throws -> TokenResponse
    {
        var request = URLRequest(url: AntigravityOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "code": code,
            "client_id": oauthClient.clientID,
            "client_secret": oauthClient.clientSecret,
            "redirect_uri": redirectURL.absoluteString,
            "grant_type": "authorization_code",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityLoginError.failed("Invalid token response.")
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "HTTP \(httpResponse.statusCode)"
            throw AntigravityLoginError.failed(message)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AntigravityLoginError.failed("Could not decode token response.")
        }
    }

    private static func fetchUserEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: AntigravityOAuthConfig.userInfoURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let userInfo = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            let email = userInfo.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (email?.isEmpty == false) ? email : nil
        } catch {
            return nil
        }
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        values
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}

private enum AntigravityLoginError: LocalizedError {
    case invalidAuthorizationURL
    case timedOut
    case launchFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            "Could not build the Antigravity login URL."
        case .timedOut:
            "Antigravity login timed out."
        case let .launchFailed(message):
            message
        case let .failed(message):
            message
        }
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

private struct UserInfoResponse: Decodable {
    let email: String?
}

private struct AntigravityOAuthCallback {
    let code: String?
    let returnedState: String?
    let error: String?
}

private final class AntigravityLoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "codexbar.antigravity.oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<AntigravityOAuthCallback, Error>?
    private var pendingCallbackResult: Result<AntigravityOAuthCallback, Error>?
    private var completed = false

    init(state: String) {
        self.expectedState = state
    }

    func start() async throws -> URL {
        let port = try Self.findAvailablePort()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw AntigravityLoginError.failed("Could not reserve a local callback port.")
        }
        let listener = try NWListener(using: .tcp, on: endpointPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let url = URL(string: "http://127.0.0.1:\(port)/callback")!
                    self.finishReady(with: .success(url))
                case let .failed(error):
                    self.finishReady(with: .failure(error))
                    self.finishCallback(with: .failure(error))
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    func waitForCallback() async throws -> AntigravityOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            defer { self.lock.unlock() }
            if let pending = self.pendingCallbackResult {
                self.pendingCallbackResult = nil
                switch pending {
                case let .success(callback):
                    continuation.resume(returning: callback)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
                return
            }
            self.callbackContinuation = continuation
        }
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    func cancelCallbackWait(with error: Error) {
        self.stop()
        self.finishCallback(with: .failure(error))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finishCallback(with: .failure(error))
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            let headerMarker = Data("\r\n\r\n".utf8)
            if buffer.range(of: headerMarker) == nil, !isComplete {
                self.receive(on: connection, accumulated: buffer)
                return
            }

            let callback = self.parseCallback(from: buffer)
            let response = self.httpResponse(for: callback)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finishCallback(with: .success(callback))
        }
    }

    private func parseCallback(from data: Data) -> AntigravityOAuthCallback {
        guard let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first
        else {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "Invalid callback request.")
        }

        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "Invalid callback URL.")
        }

        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        let error = components.queryItems?.first(where: { $0.name == "error" })?.value

        guard components.path == "/callback" else {
            return AntigravityOAuthCallback(code: nil, returnedState: returnedState, error: "Unexpected callback path.")
        }
        if let returnedState, returnedState != self.expectedState {
            return AntigravityOAuthCallback(code: code, returnedState: returnedState, error: "State mismatch.")
        }
        return AntigravityOAuthCallback(code: code, returnedState: returnedState, error: error)
    }

    private func httpResponse(for callback: AntigravityOAuthCallback) -> Data {
        let success = callback.error == nil && callback.code?.isEmpty == false
        let status = success ? "200 OK" : "400 Bad Request"
        let title = success ? "Login Successful" : "Login Failed"
        let detail = success
            ? "You can close this window and return to CodexBar."
            : "You can close this window and try again."
        let html = """
        <html>
          <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 32px; text-align: center;">
            <h1>\(title)</h1>
            <p>\(detail)</p>
          </body>
        </html>
        """
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func finishReady(with result: Result<URL, Error>) {
        self.lock.lock()
        let continuation = self.readyContinuation
        self.readyContinuation = nil
        self.lock.unlock()
        switch result {
        case let .success(url):
            continuation?.resume(returning: url)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func finishCallback(with result: Result<AntigravityOAuthCallback, Error>) {
        self.lock.lock()
        guard !self.completed else {
            self.lock.unlock()
            return
        }
        self.completed = true
        let continuation = self.callbackContinuation
        self.callbackContinuation = nil
        if continuation == nil {
            self.pendingCallbackResult = result
        }
        self.lock.unlock()
        guard let continuation else { return }
        switch result {
        case let .success(callback):
            continuation.resume(returning: callback)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private static func findAvailablePort() throws -> UInt16 {
        let socketFD = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard socketFD >= 0 else {
            throw AntigravityLoginError.failed("Could not create a local callback socket.")
        }
        defer { close(socketFD) }

        var value: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            throw AntigravityLoginError.failed("Could not bind a local callback port.")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw AntigravityLoginError.failed("Could not inspect the callback port.")
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }
}

extension CharacterSet {
    fileprivate static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}
