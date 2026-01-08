import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?, resetDescription: String?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

public struct ProviderIdentitySnapshot: Codable, Sendable {
    public let providerID: UsageProvider?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?

    public init(
        providerID: UsageProvider?,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?)
    {
        self.providerID = providerID
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
    }

    public func scoped(to provider: UsageProvider) -> ProviderIdentitySnapshot {
        if self.providerID == provider { return self }
        return ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod)
    }
}

public struct UsageSnapshot: Codable, Sendable {
    public let primary: RateWindow?
    public let secondary: RateWindow?
    public let tertiary: RateWindow?
    public let providerCost: ProviderCostSnapshot?
    public let zaiUsage: ZaiUsageSnapshot?
    public let minimaxUsage: MiniMaxUsageSnapshot?
    public let cursorRequests: CursorRequestUsage?
    public let updatedAt: Date
    public let identity: ProviderIdentitySnapshot?

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case tertiary
        case providerCost
        case updatedAt
        case identity
        case accountEmail
        case accountOrganization
        case loginMethod
    }

    public init(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        providerCost: ProviderCostSnapshot? = nil,
        zaiUsage: ZaiUsageSnapshot? = nil,
        minimaxUsage: MiniMaxUsageSnapshot? = nil,
        cursorRequests: CursorRequestUsage? = nil,
        updatedAt: Date,
        identity: ProviderIdentitySnapshot? = nil)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.providerCost = providerCost
        self.zaiUsage = zaiUsage
        self.minimaxUsage = minimaxUsage
        self.cursorRequests = cursorRequests
        self.updatedAt = updatedAt
        self.identity = identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decodeIfPresent(RateWindow.self, forKey: .primary)
        self.secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
        self.tertiary = try container.decodeIfPresent(RateWindow.self, forKey: .tertiary)
        self.providerCost = try container.decodeIfPresent(ProviderCostSnapshot.self, forKey: .providerCost)
        self.zaiUsage = nil // Not persisted, fetched fresh each time
        self.minimaxUsage = nil // Not persisted, fetched fresh each time
        self.cursorRequests = nil // Not persisted, fetched fresh each time
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let identity = try container.decodeIfPresent(ProviderIdentitySnapshot.self, forKey: .identity) {
            self.identity = identity
        } else {
            let email = try container.decodeIfPresent(String.self, forKey: .accountEmail)
            let organization = try container.decodeIfPresent(String.self, forKey: .accountOrganization)
            let loginMethod = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            if email != nil || organization != nil || loginMethod != nil {
                self.identity = ProviderIdentitySnapshot(
                    providerID: nil,
                    accountEmail: email,
                    accountOrganization: organization,
                    loginMethod: loginMethod)
            } else {
                self.identity = nil
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Stable JSON schema: keep window keys present (encode `nil` as `null`).
        try container.encode(self.primary, forKey: .primary)
        try container.encode(self.secondary, forKey: .secondary)
        try container.encode(self.tertiary, forKey: .tertiary)
        try container.encodeIfPresent(self.providerCost, forKey: .providerCost)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.identity, forKey: .identity)
        try container.encodeIfPresent(self.identity?.accountEmail, forKey: .accountEmail)
        try container.encodeIfPresent(self.identity?.accountOrganization, forKey: .accountOrganization)
        try container.encodeIfPresent(self.identity?.loginMethod, forKey: .loginMethod)
    }

    public func identity(for provider: UsageProvider) -> ProviderIdentitySnapshot? {
        guard let identity, identity.providerID == provider else { return nil }
        return identity
    }

    public func accountEmail(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.accountEmail
    }

    public func accountOrganization(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.accountOrganization
    }

    public func loginMethod(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.loginMethod
    }

    public func scoped(to provider: UsageProvider) -> UsageSnapshot {
        guard let identity else { return self }
        let scopedIdentity = identity.scoped(to: provider)
        if scopedIdentity.providerID == identity.providerID { return self }
        return UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            tertiary: self.tertiary,
            providerCost: self.providerCost,
            zaiUsage: self.zaiUsage,
            minimaxUsage: self.minimaxUsage,
            cursorRequests: self.cursorRequests,
            updatedAt: self.updatedAt,
            identity: scopedIdentity)
    }
}

public struct AccountInfo: Equatable, Sendable {
    public let email: String?
    public let plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}

public enum UsageError: LocalizedError, Sendable {
    case noSessions
    case noRateLimitsFound
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .noSessions:
            "No Codex sessions found yet. Run at least one Codex prompt first."
        case .noRateLimitsFound:
            "Found sessions, but no rate limit events yet."
        case .decodeFailed:
            "Could not parse Codex session log."
        }
    }
}

// MARK: - Codex RPC client (local process)

private struct RPCAccountResponse: Decodable {
    let account: RPCAccountDetails?
    let requiresOpenaiAuth: Bool?
}

private enum RPCAccountDetails: Decodable {
    case apiKey
    case chatgpt(email: String, planType: String)

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type.lowercased() {
        case "apikey":
            self = .apiKey
        case "chatgpt":
            let email = try container.decodeIfPresent(String.self, forKey: .email) ?? "unknown"
            let plan = try container.decodeIfPresent(String.self, forKey: .planType) ?? "unknown"
            self = .chatgpt(email: email, planType: plan)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown account type \(type)")
        }
    }
}

private struct RPCRateLimitsResponse: Decodable, Encodable {
    let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable, Encodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
}

private struct RPCRateLimitWindow: Decodable, Encodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct RPCCreditsSnapshot: Decodable, Encodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

private enum RPCWireError: Error, LocalizedError {
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .startFailed(message):
            "Codex not running. Try running a Codex command first. (\(message))"
        case let .requestFailed(message):
            "Codex connection failed: \(message)"
        case let .malformed(message):
            "Codex returned invalid data: \(message)"
        }
    }
}

// RPC helper used on background tasks; safe because we confine it to the owning task.
private final class CodexRPCClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func appendAndDrainLines(_ data: Data) -> [Data] {
            self.lock.lock()
            defer { self.lock.unlock() }

            self.buffer.append(data)
            var out: [Data] = []
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = Data(self.buffer[..<newline])
                self.buffer.removeSubrange(...newline)
                if !lineData.isEmpty {
                    out.append(lineData)
                }
            }
            return out
        }
    }

    private static func debugWriteStderr(_ message: String) {
        #if !os(Linux)
        fputs(message, stderr)
        #endif
    }

    init(
        executable: String = "codex",
        arguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server"]) throws
    {
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutLineContinuation = stdoutContinuation

        let resolvedExec = BinaryLocator.resolveCodexBinary()
            ?? TTYCommandRunner.which(executable)

        guard let resolvedExec else {
            throw RPCWireError.startFailed(
                "Codex CLI not found. Install with `npm i -g @openai/codex` (or bun) then relaunch CodexBar.")
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .nodeTooling],
            env: env)

        self.process.environment = env
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = [resolvedExec] + arguments
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
        } catch {
            throw RPCWireError.startFailed(error.localizedDescription)
        }

        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stdoutLineContinuation = self.stdoutLineContinuation
        let stdoutBuffer = LineBuffer()
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutLineContinuation.finish()
                return
            }

            let lines = stdoutBuffer.appendAndDrainLines(data)

            for lineData in lines {
                stdoutLineContinuation.yield(lineData)
            }
        }

        let stderrHandle = self.stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            // When the child closes stderr, availableData returns empty and will keep re-firing; clear the handler
            // to avoid a busy read loop on the file-descriptor monitoring queue.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                Self.debugWriteStderr("[codex stderr] \(line)\n")
            }
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await self.request(
            method: "initialize",
            params: ["clientInfo": ["name": clientName, "version": clientVersion]])
        try self.sendNotification(method: "initialized")
    }

    func fetchAccount() async throws -> RPCAccountResponse {
        let message = try await self.request(method: "account/read")
        return try self.decodeResult(from: message)
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        let message = try await self.request(method: "account/rateLimits/read")
        return try self.decodeResult(from: message)
    }

    func shutdown() {
        if self.process.isRunning {
            self.process.terminate()
        }
    }

    // MARK: - JSON-RPC helpers

    private func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        while true {
            let message = try await self.readNextMessage()

            if message["id"] == nil, let methodName = message["method"] as? String {
                Self.debugWriteStderr("[codex notify] \(methodName)\n")
                continue
            }

            guard let messageID = self.jsonID(message["id"]), messageID == id else { continue }

            if let error = message["error"] as? [String: Any], let messageText = error["message"] as? String {
                throw RPCWireError.requestFailed(messageText)
            }

            return message
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        let paramsValue: Any = params ?? [:]
        try self.sendPayload(["method": method, "params": paramsValue])
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        let paramsValue: Any = params ?? [:]
        let payload: [String: Any] = ["id": id, "method": method, "params": paramsValue]
        try self.sendPayload(payload)
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        self.stdinPipe.fileHandleForWriting.write(data)
        self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await lineData in self.stdoutLineStream {
            if lineData.isEmpty { continue }
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return json
            }
        }
        throw RPCWireError.malformed("codex app-server closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw RPCWireError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let number as NSNumber:
            number.intValue
        default:
            nil
        }
    }
}

// MARK: - Public fetcher used by the app

public struct UsageFetcher: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        LoginShellPathCache.shared.captureOnce()
    }

    public func loadLatestUsage() async throws -> UsageSnapshot {
        try await self.withFallback(primary: self.loadRPCUsage, secondary: self.loadTTYUsage)
    }

    private func loadRPCUsage() async throws -> UsageSnapshot {
        let rpc = try CodexRPCClient()
        defer { rpc.shutdown() }

        try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
        // The app-server answers on a single stdout stream, so keep requests
        // serialized to avoid starving one reader when multiple awaiters race
        // for the same pipe.
        let limits = try await rpc.fetchRateLimits().rateLimits
        let account = try? await rpc.fetchAccount()

        guard let primary = Self.makeWindow(from: limits.primary),
              let secondary = Self.makeWindow(from: limits.secondary)
        else {
            throw UsageError.noRateLimitsFound
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: account?.account.flatMap { details in
                if case let .chatgpt(email, _) = details { email } else { nil }
            },
            accountOrganization: nil,
            loginMethod: account?.account.flatMap { details in
                if case let .chatgpt(_, plan) = details { plan } else { nil }
            })
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private func loadTTYUsage() async throws -> UsageSnapshot {
        let status = try await CodexStatusProbe().fetch()
        guard let fiveLeft = status.fiveHourPercentLeft, let weekLeft = status.weeklyPercentLeft else {
            throw UsageError.noRateLimitsFound
        }

        let primary = RateWindow(
            usedPercent: max(0, 100 - Double(fiveLeft)),
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: status.fiveHourResetDescription)
        let secondary = RateWindow(
            usedPercent: max(0, 100 - Double(weekLeft)),
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: status.weeklyResetDescription)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: nil)
    }

    public func loadLatestCredits() async throws -> CreditsSnapshot {
        try await self.withFallback(primary: self.loadRPCCredits, secondary: self.loadTTYCredits)
    }

    private func loadRPCCredits() async throws -> CreditsSnapshot {
        let rpc = try CodexRPCClient()
        defer { rpc.shutdown() }
        try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
        let limits = try await rpc.fetchRateLimits().rateLimits
        guard let credits = limits.credits else { throw UsageError.noRateLimitsFound }
        let remaining = Self.parseCredits(credits.balance)
        return CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
    }

    private func loadTTYCredits() async throws -> CreditsSnapshot {
        let status = try await CodexStatusProbe().fetch()
        guard let credits = status.credits else { throw UsageError.noRateLimitsFound }
        return CreditsSnapshot(remaining: credits, events: [], updatedAt: Date())
    }

    private func withFallback<T>(
        primary: @escaping () async throws -> T,
        secondary: @escaping () async throws -> T) async throws -> T
    {
        do {
            return try await primary()
        } catch let primaryError {
            do {
                return try await secondary()
            } catch {
                // Preserve the original failure so callers see the primary path error.
                throw primaryError
            }
        }
    }

    public func debugRawRateLimits() async -> String {
        do {
            let rpc = try CodexRPCClient()
            defer { rpc.shutdown() }
            try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
            let limits = try await rpc.fetchRateLimits()
            let data = try JSONEncoder().encode(limits)
            return String(data: data, encoding: .utf8) ?? "<unprintable>"
        } catch {
            return "Codex RPC probe failed: \(error)"
        }
    }

    public func loadAccountInfo() -> AccountInfo {
        // Keep using auth.json for quick startup (non-blocking, no RPC spin-up required).
        let authURL = URL(fileURLWithPath: self.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex")
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let idToken = auth.tokens?.idToken
        else {
            return AccountInfo(email: nil, plan: nil)
        }

        guard let payload = UsageFetcher.parseJWT(idToken) else {
            return AccountInfo(email: nil, plan: nil)
        }

        let authDict = payload["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = payload["https://api.openai.com/profile"] as? [String: Any]

        let plan = (authDict?["chatgpt_plan_type"] as? String)
            ?? (payload["chatgpt_plan_type"] as? String)

        let email = (payload["email"] as? String)
            ?? (profileDict?["email"] as? String)

        return AccountInfo(email: email, plan: plan)
    }

    // MARK: - Helpers

    private static func makeWindow(from rpc: RPCRateLimitWindow?) -> RateWindow? {
        guard let rpc else { return nil }
        let resetsAtDate = rpc.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let resetDescription = resetsAtDate.map { UsageFormatter.resetDescription(from: $0) }
        return RateWindow(
            usedPercent: rpc.usedPercent,
            windowMinutes: rpc.windowDurationMins,
            resetsAt: resetsAtDate,
            resetDescription: resetDescription)
    }

    private static func parseCredits(_ balance: String?) -> Double {
        guard let balance, let val = Double(balance) else { return 0 }
        return val
    }

    public static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payloadPart = parts[1]

        var padded = String(payloadPart)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}

// Minimal auth.json struct preserved from previous implementation
private struct AuthFile: Decodable {
    struct Tokens: Decodable { let idToken: String? }
    let tokens: Tokens?
}
