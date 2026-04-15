import Foundation

// MARK: - OpenClaw Gateway WebSocket Client

/// Authenticated WebSocket client for OpenClaw's gateway JSON-RPC API.
///
/// Replaces insecure file-write injection with proper authenticated RPC:
/// - Reads gateway token from `~/.openclaw/gateway.token`
/// - Connects via `ws://127.0.0.1:{port}`
/// - Sends `config.get` / `config.patch` JSON-RPC messages
/// - Handles responses with timeout
///
/// Security: Token-authenticated, no file writes, no shell scripts, no kill -9.
public final class OpenClawGatewayClient: Sendable {

    // MARK: - Error Types

    public enum GatewayError: Error, LocalizedError, Sendable {
        case tokenNotFound(path: String)
        case tokenUnreadable(path: String)
        case connectionFailed(port: Int, underlying: String)
        case timeout(seconds: Int)
        case disconnected
        case rpcError(method: String, message: String)
        case invalidResponse(String)
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .tokenNotFound(let path):
                return "Gateway token not found at \(path)"
            case .tokenUnreadable(let path):
                return "Gateway token unreadable at \(path) — check permissions (should be 0600)"
            case .connectionFailed(let port, let underlying):
                return "Failed to connect to gateway on port \(port): \(underlying)"
            case .timeout(let seconds):
                return "Gateway request timed out after \(seconds)s"
            case .disconnected:
                return "WebSocket disconnected unexpectedly"
            case .rpcError(let method, let message):
                return "RPC error on \(method): \(message)"
            case .invalidResponse(let detail):
                return "Invalid gateway response: \(detail)"
            case .notConnected:
                return "Not connected to gateway — call connect() first"
            }
        }
    }

    // MARK: - Result Types

    /// Result of a config.get call.
    public struct ConfigSnapshot: Sendable {
        public let raw: String      // Full JSON config
        public let baseHash: String // SHA for optimistic concurrency
    }

    /// Result of a config.patch call.
    public struct PatchResult: Sendable {
        public let ok: Bool
        public let newHash: String?
    }

    // MARK: - Internal State Actor

    /// Actor-isolated mutable state for pending RPC requests.
    /// Uses raw JSON Data to stay Sendable across isolation boundaries.
    private actor RequestState {
        var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]

        func register(id: String, continuation: CheckedContinuation<Data, Error>) {
            pendingRequests[id] = continuation
        }

        func complete(id: String, data: Data) {
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            continuation.resume(returning: data)
        }

        func fail(id: String, error: Error) {
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            continuation.resume(throwing: error)
        }

        func cancelAll(error: Error) {
            let pending = pendingRequests
            pendingRequests.removeAll()
            for (_, continuation) in pending {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Properties

    private let port: Int
    private let timeoutSeconds: Int
    private let session: URLSession
    private let state = RequestState()

    // Non-isolated mutable state — only accessed from connect/disconnect
    // which are expected to be called sequentially (not concurrently).
    nonisolated(unsafe) private var webSocketTask: URLSessionWebSocketTask?

    // MARK: - Init

    /// Create a client targeting a specific gateway port.
    /// - Parameters:
    ///   - port: Gateway port (default 18789)
    ///   - timeoutSeconds: Request timeout (default 30)
    public init(port: Int = 18789, timeoutSeconds: Int = 30) {
        self.port = port
        self.timeoutSeconds = timeoutSeconds
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
        self.session = URLSession(configuration: config)
    }

    // MARK: - Token Reading

    /// Read the gateway authentication token from disk.
    /// The token file is at `~/.openclaw/gateway.token` (48 bytes, 0600 permissions).
    public static func readGatewayToken() throws -> String {
        let tokenPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/gateway.token")

        guard FileManager.default.fileExists(atPath: tokenPath.path) else {
            throw GatewayError.tokenNotFound(path: tokenPath.path)
        }

        guard let data = FileManager.default.contents(atPath: tokenPath.path),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw GatewayError.tokenUnreadable(path: tokenPath.path)
        }

        return token
    }

    // MARK: - Auth Modes

    /// Gateway authentication mode — supports all OpenClaw auth options.
    public enum AuthMode: Sendable {
        case token           // Auto-read from ~/.openclaw/gateway.token
        case tokenValue(String)  // Explicit token value
        case password(String)    // Password-based auth
    }

    // MARK: - Connection

    /// Connect to the gateway WebSocket with authentication.
    /// Supports token (auto-read or explicit) and password auth modes.
    /// - Parameter authMode: How to authenticate (default: auto-read token from disk)
    public func connect(authMode: AuthMode = .token) async throws {
        let authParam: String
        switch authMode {
        case .token:
            let token = try Self.readGatewayToken()
            authParam = "token=\(token)"
        case .tokenValue(let token):
            authParam = "token=\(token)"
        case .password(let password):
            authParam = "password=\(password)"
        }

        // Gateway accepts auth via query parameter for WebSocket connections
        guard let url = URL(string: "ws://127.0.0.1:\(port)?\(authParam)") else {
            throw GatewayError.connectionFailed(port: port, underlying: "Invalid URL")
        }

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Start the receive loop
        Task { [weak self] in
            await self?.receiveLoop()
        }

        // Verify connection with a small delay to let the handshake complete
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Verify the connection is open by checking state
        guard task.state == .running else {
            throw GatewayError.connectionFailed(port: port, underlying: "WebSocket handshake failed")
        }
    }

    /// Disconnect from the gateway.
    public func disconnect() async {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        await state.cancelAll(error: GatewayError.disconnected)
    }

    // MARK: - RPC Methods

    /// Fetch the current gateway config and its base hash.
    /// The base hash is required for `configPatch` (optimistic concurrency).
    public func configGet() async throws -> ConfigSnapshot {
        let responseData = try await sendRPC(method: "config.get", params: [:])
        let response = try parseResponse(responseData)

        guard let payload = response["payload"] as? [String: Any],
              let raw = payload["raw"] as? String,
              let baseHash = payload["baseHash"] as? String
        else {
            throw GatewayError.invalidResponse("config.get payload missing raw or baseHash")
        }

        return ConfigSnapshot(raw: raw, baseHash: baseHash)
    }

    /// Apply a merge-patch to the gateway config.
    /// - Parameters:
    ///   - patch: JSON string containing the merge-patch to apply
    ///   - baseHash: The base hash from a prior `configGet()` call
    /// - Returns: Result indicating success and the new config hash
    public func configPatch(patch: String, baseHash: String) async throws -> PatchResult {
        let params: [String: Any] = [
            "raw": patch,
            "baseHash": baseHash,
        ]
        let responseData = try await sendRPC(method: "config.patch", params: params)
        let response = try parseResponse(responseData)

        let ok = response["ok"] as? Bool ?? false
        if !ok {
            let msg = response["error"] as? String ?? "unknown error"
            throw GatewayError.rpcError(method: "config.patch", message: msg)
        }

        let newHash = (response["payload"] as? [String: Any])?["baseHash"] as? String
        return PatchResult(ok: true, newHash: newHash)
    }

    private func parseResponse(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayError.invalidResponse("Could not parse response JSON")
        }
        return json
    }

    // MARK: - Internal RPC

    private func sendRPC(method: String, params: [String: Any]) async throws -> Data {
        guard let task = webSocketTask, task.state == .running else {
            throw GatewayError.notConnected
        }

        let requestId = UUID().uuidString

        let message: [String: Any] = [
            "type": "request",
            "id": requestId,
            "method": method,
            "params": params,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            throw GatewayError.invalidResponse("Failed to serialize RPC request")
        }

        // Register continuation before sending, with per-RPC timeout to prevent
        // hanging indefinitely if the gateway never replies.
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await self.state.register(id: requestId, continuation: continuation)
                        do {
                            try await task.send(.string(jsonString))
                        } catch {
                            await self.state.fail(
                                id: requestId,
                                error: GatewayError.connectionFailed(
                                    port: self.port, underlying: error.localizedDescription))
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds) * 1_000_000_000)
                throw GatewayError.timeout(seconds: self.timeoutSeconds)
            }
            // First to complete wins — either the response or the timeout
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while task.state == .running {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                // Connection closed or error — cancel all pending
                await state.cancelAll(error: GatewayError.disconnected)
                return
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }

        // Parse just enough to extract the request ID for routing
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "response",
              let id = json["id"] as? String
        else { return }

        // Pass the raw Data through — deserialization happens on the caller side
        await state.complete(id: id, data: data)
    }
}

// MARK: - Config Patch Builder

/// Builds a JSON merge-patch from an OpenClawExport for use with config.patch.
/// Only touches LM-related keys — preserves everything else in the config.
public enum OpenClawPatchBuilder {

    /// Convert an OpenClawExport into a JSON merge-patch string.
    /// The patch only includes: models.providers, agents.defaults.model,
    /// auth.profiles, auth.order, auth.cooldowns, plugins.entries.
    public static func buildPatch(from export: OpenClawExport) -> String {
        var patch: [String: Any] = [:]

        // models.providers
        if !export.providers.isEmpty {
            var providersDict: [String: Any] = [:]
            for (key, provider) in export.providers {
                var modelsArray: [[String: Any]] = []
                for model in provider.models {
                    modelsArray.append([
                        "id": model.id,
                        "name": model.name,
                        "reasoning": model.reasoning,
                        "input": model.input,
                        "cost": [
                            "input": model.cost.input,
                            "output": model.cost.output,
                            "cacheRead": model.cost.cacheRead,
                            "cacheWrite": model.cost.cacheWrite,
                        ],
                        "contextWindow": model.contextWindow,
                        "maxTokens": model.maxTokens,
                    ])
                }
                var providerDict: [String: Any] = [
                    "api": provider.api,
                    "baseUrl": provider.baseUrl,
                    "models": modelsArray,
                ]
                if let apiKey = provider.apiKey {
                    providerDict["apiKey"] = apiKey
                }
                providersDict[key] = providerDict
            }
            patch["models"] = ["providers": providersDict]
        }

        // agents.defaults.model
        patch["agents"] = [
            "defaults": [
                "model": [
                    "primary": export.primary,
                    "fallbacks": export.fallbacks,
                ] as [String: Any],
            ] as [String: Any],
        ]

        // auth — profiles, order, cooldowns
        var authDict: [String: Any] = [:]

        if !export.authProfiles.isEmpty {
            var profilesDict: [String: Any] = [:]
            for (key, profile) in export.authProfiles {
                var p: [String: Any] = [
                    "provider": profile.provider,
                ]
                let modeValue: String = profile.mode ?? profile.type
                p["mode"] = modeValue
                // Include API key if present — needed for Ollama and other
                // API-key-based providers to actually authenticate requests.
                if let apiKey = profile.key, !apiKey.isEmpty {
                    p["key"] = apiKey
                }
                if let accountId = profile.accountId, !accountId.isEmpty {
                    p["accountId"] = accountId
                }
                profilesDict[key] = p
            }
            authDict["profiles"] = profilesDict
        }

        if !export.authOrder.isEmpty {
            authDict["order"] = export.authOrder
        }

        authDict["cooldowns"] = [
            "billingBackoffHours": export.authCooldowns.billingBackoffHours,
            "authPermanentBackoffMinutes": export.authCooldowns.authPermanentBackoffMinutes,
        ]

        patch["auth"] = authDict

        // plugins.entries
        if !export.plugins.isEmpty {
            var entriesDict: [String: Any] = [:]
            for (key, plugin) in export.plugins {
                entriesDict[key] = ["enabled": plugin.enabled]
            }
            patch["plugins"] = ["entries": entriesDict]
        }

        // Serialize
        guard let data = try? JSONSerialization.data(
            withJSONObject: patch,
            options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }

        return json
    }
}
