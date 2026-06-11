import AppKit
import CodexBarCore
import CryptoKit
import Foundation
import Network

enum PoeLoginRunner {
    enum Phase {
        case waitingBrowser
    }

    struct Result {
        enum Outcome {
            case success(expiresInSeconds: Int?)
            case cancelled
            case timedOut
            case launchFailed(String)
            case failed(String)
        }

        let outcome: Outcome
    }

    struct OAuthToken: Sendable {
        let apiKey: String
        let expiresInSeconds: Int?
    }

    static func run(
        timeout: TimeInterval = 120,
        onPhaseChange: (@Sendable (Phase) -> Void)? = nil,
        onTokenCreated: (@Sendable (OAuthToken) -> Void)? = nil) async -> Result
    {
        guard let clientID = self.oauthClientID() else {
            return Result(outcome: .failed(
                "Missing POE_OAUTH_CLIENT_ID. Create a client at poe.com/api/clients and set the env var."))
        }

        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let verifier = self.makeCodeVerifier()
        let challenge = self.makeCodeChallenge(from: verifier)
        let server = PoeLoopbackServer(expectedState: state)

        do {
            let redirectURL = try await server.start()
            let authURL = try self.makeAuthorizationURL(
                clientID: clientID,
                redirectURL: redirectURL,
                state: state,
                codeChallenge: challenge)
            onPhaseChange?(.waitingBrowser)

            let opened = await MainActor.run { NSWorkspace.shared.open(authURL) }
            guard opened else {
                server.stop()
                return Result(outcome: .launchFailed(authURL.absoluteString))
            }

            let callback = try await withThrowingTaskGroup(of: PoeOAuthCallback.self) { group in
                group.addTask { try await server.waitForCallback() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    server.cancelCallbackWait(with: PoeLoginError.timedOut)
                    throw PoeLoginError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next().unsafelyUnwrapped
            }
            server.stop()

            if let error = callback.error, !error.isEmpty {
                if error == "access_denied" {
                    return Result(outcome: .cancelled)
                }
                let message = callback.errorDescription ?? error
                return Result(outcome: .failed(message))
            }

            guard callback.returnedState == state else {
                return Result(outcome: .failed("Poe login state mismatch."))
            }
            guard let code = callback.code, !code.isEmpty else {
                return Result(outcome: .failed("Poe login did not return an authorization code."))
            }

            let token = try await self.exchangeCodeForAPIKey(
                clientID: clientID,
                code: code,
                redirectURL: redirectURL,
                codeVerifier: verifier)
            onTokenCreated?(token)
            return Result(outcome: .success(expiresInSeconds: token.expiresInSeconds))
        } catch is CancellationError {
            server.stop()
            return Result(outcome: .cancelled)
        } catch PoeLoginError.timedOut {
            server.stop()
            return Result(outcome: .timedOut)
        } catch let PoeLoginError.launchFailed(message) {
            server.stop()
            return Result(outcome: .launchFailed(message))
        } catch {
            server.stop()
            return Result(outcome: .failed(error.localizedDescription))
        }
    }

    private static func oauthClientID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let value = environment["POE_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func makeAuthorizationURL(
        clientID: String,
        redirectURL: URL,
        state: String,
        codeChallenge: String) throws -> URL
    {
        guard var components = URLComponents(string: "https://poe.com/oauth/authorize") else {
            throw PoeLoginError.invalidAuthorizationURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "apikey:create"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw PoeLoginError.invalidAuthorizationURL
        }
        return url
    }

    private static func exchangeCodeForAPIKey(
        clientID: String,
        code: String,
        redirectURL: URL,
        codeVerifier: String) async throws -> OAuthToken
    {
        var request = URLRequest(url: URL(string: "https://api.poe.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = self.formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURL.absoluteString,
            "code_verifier": codeVerifier,
        ])

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PoeLoginError.failed("Invalid token response.")
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "HTTP \(httpResponse.statusCode)"
            throw PoeLoginError.failed(message)
        }

        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let parsed else {
            throw PoeLoginError.failed("Could not decode Poe token response.")
        }
        guard let apiKey = (parsed["api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw PoeLoginError.failed("Poe token response did not include api_key.")
        }
        let expiresIn = parsed["api_key_expires_in"] as? Int
        return OAuthToken(apiKey: apiKey, expiresInSeconds: expiresIn)
    }

    private static func makeCodeVerifier() -> String {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return self.base64URL(data)
    }

    private static func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return self.base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

private enum PoeLoginError: LocalizedError {
    case invalidAuthorizationURL
    case timedOut
    case launchFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            "Could not build the Poe login URL."
        case .timedOut:
            "Poe login timed out."
        case let .launchFailed(message):
            message
        case let .failed(message):
            message
        }
    }
}

private struct PoeOAuthCallback {
    let code: String?
    let returnedState: String?
    let error: String?
    let errorDescription: String?
}

private final class PoeLoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "codexbar.poe.oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<PoeOAuthCallback, Error>?
    private var pendingCallbackResult: Result<PoeOAuthCallback, Error>?
    private var completed = false

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() async throws -> URL {
        let port = try Self.findAvailablePort()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PoeLoginError.failed("Could not reserve a local callback port.")
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

    func waitForCallback() async throws -> PoeOAuthCallback {
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
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            self.finishCallback(with: .success(callback))
        }
    }

    private func parseCallback(from data: Data) -> PoeOAuthCallback {
        guard let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first
        else {
            return PoeOAuthCallback(
                code: nil,
                returnedState: nil,
                error: "invalid_request",
                errorDescription: "Invalid callback request.")
        }

        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return PoeOAuthCallback(
                code: nil,
                returnedState: nil,
                error: "invalid_request",
                errorDescription: "Invalid callback URL.")
        }

        let queryItems = components.queryItems ?? []
        let trackedNames: Set<String> = ["code", "state", "error", "error_description"]
        var query: [String: String] = [:]
        for item in queryItems where trackedNames.contains(item.name) {
            if query[item.name] != nil {
                return PoeOAuthCallback(
                    code: nil,
                    returnedState: nil,
                    error: "invalid_request",
                    errorDescription: "Duplicate callback parameter.")
            }
            query[item.name] = item.value ?? ""
        }

        let code = query["code"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let returnedState = query["state"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = query["error"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorDescription = query["error_description"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if returnedState != nil, returnedState != self.expectedState {
            return PoeOAuthCallback(
                code: nil,
                returnedState: returnedState,
                error: "invalid_request",
                errorDescription: "State mismatch.")
        }
        return PoeOAuthCallback(
            code: code,
            returnedState: returnedState,
            error: error,
            errorDescription: errorDescription)
    }

    private func httpResponse(for callback: PoeOAuthCallback) -> Data {
        let message = if callback.error == nil, callback.code?.isEmpty == false {
            "Poe login complete. You can return to CodexBar."
        } else if let error = callback.errorDescription, !error.isEmpty {
            "Poe login failed: \(error)"
        } else {
            "Poe login failed."
        }
        let body = """
        <html><body style=\"font-family:-apple-system,Segoe UI,sans-serif;padding:24px;\">
        <h2>CodexBar</h2><p>\(message)</p></body></html>
        """
        let statusLine = (callback.error == nil && callback.code?.isEmpty == false)
            ? "HTTP/1.1 200 OK"
            : "HTTP/1.1 400 Bad Request"
        let payload = """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        return Data(payload.utf8)
    }

    private func finishReady(with result: Result<URL, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let continuation = self.readyContinuation else { return }
        self.readyContinuation = nil
        switch result {
        case let .success(url):
            continuation.resume(returning: url)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func finishCallback(with result: Result<PoeOAuthCallback, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.completed else { return }
        self.completed = true

        if let continuation = self.callbackContinuation {
            self.callbackContinuation = nil
            switch result {
            case let .success(value):
                continuation.resume(returning: value)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        } else {
            self.pendingCallbackResult = result
        }
    }

    private static func findAvailablePort() throws -> UInt16 {
        var addresses: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo(
            ai_flags: AI_PASSIVE,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        let status = getaddrinfo("127.0.0.1", "0", &hints, &addresses)
        guard status == 0, let addresses else {
            throw PoeLoginError.failed("Could not allocate local callback address.")
        }
        defer { freeaddrinfo(addresses) }

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw PoeLoginError.failed("Could not create local callback socket.")
        }
        defer { close(socketFD) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bound = false
        var pointer: UnsafeMutablePointer<addrinfo>? = addresses
        while let current = pointer {
            if Darwin.bind(socketFD, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                bound = true
                break
            }
            pointer = current.pointee.ai_next
        }
        guard bound else {
            throw PoeLoginError.failed("Could not bind local callback socket.")
        }

        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(socketFD, sockPtr, &length)
            }
        }) == 0 else {
            throw PoeLoginError.failed("Could not read callback socket port.")
        }

        return UInt16(bigEndian: address.sin_port)
    }
}

extension PoeLoginRunner {
    static func _parseCallbackForTesting(_ request: String, expectedState: String) -> (
        code: String?,
        returnedState: String?,
        error: String?,
        errorDescription: String?)
    {
        let callback = PoeLoopbackServer(expectedState: expectedState)
            .parseCallback(from: Data(request.utf8))
        return (
            code: callback.code,
            returnedState: callback.returnedState,
            error: callback.error,
            errorDescription: callback.errorDescription)
    }
}

extension CharacterSet {
    fileprivate static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?")
        return set
    }()
}
