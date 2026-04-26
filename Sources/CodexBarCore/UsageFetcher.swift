import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        nextRegenPercent: Double? = nil)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

public struct NamedRateWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let window: RateWindow

    public init(id: String, title: String, window: RateWindow) {
        self.id = id
        self.title = title
        self.window = window
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
    public let extraRateWindows: [NamedRateWindow]?
    public let providerCost: ProviderCostSnapshot?
    public let zaiUsage: ZaiUsageSnapshot?
    public let minimaxUsage: MiniMaxUsageSnapshot?
    public let openRouterUsage: OpenRouterUsageSnapshot?
    public let cursorRequests: CursorRequestUsage?
    public let updatedAt: Date
    public let identity: ProviderIdentitySnapshot?

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case tertiary
        case extraRateWindows
        case providerCost
        case openRouterUsage
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
        extraRateWindows: [NamedRateWindow]? = nil,
        providerCost: ProviderCostSnapshot? = nil,
        zaiUsage: ZaiUsageSnapshot? = nil,
        minimaxUsage: MiniMaxUsageSnapshot? = nil,
        openRouterUsage: OpenRouterUsageSnapshot? = nil,
        cursorRequests: CursorRequestUsage? = nil,
        updatedAt: Date,
        identity: ProviderIdentitySnapshot? = nil)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
        self.providerCost = providerCost
        self.zaiUsage = zaiUsage
        self.minimaxUsage = minimaxUsage
        self.openRouterUsage = openRouterUsage
        self.cursorRequests = cursorRequests
        self.updatedAt = updatedAt
        self.identity = identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decodeIfPresent(RateWindow.self, forKey: .primary)
        self.secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
        self.tertiary = try container.decodeIfPresent(RateWindow.self, forKey: .tertiary)
        self.extraRateWindows = try container.decodeIfPresent([NamedRateWindow].self, forKey: .extraRateWindows)
        self.providerCost = try container.decodeIfPresent(ProviderCostSnapshot.self, forKey: .providerCost)
        self.zaiUsage = nil // Not persisted, fetched fresh each time
        self.minimaxUsage = nil // Not persisted, fetched fresh each time
        self.openRouterUsage = try container.decodeIfPresent(OpenRouterUsageSnapshot.self, forKey: .openRouterUsage)
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
        try container.encodeIfPresent(self.extraRateWindows, forKey: .extraRateWindows)
        try container.encodeIfPresent(self.providerCost, forKey: .providerCost)
        try container.encodeIfPresent(self.openRouterUsage, forKey: .openRouterUsage)
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

    public func automaticPerplexityWindow() -> RateWindow? {
        let fallbackWindows = self.orderedPerplexityFallbackWindows()
        guard let primary = self.primary else {
            return fallbackWindows.first
        }
        if primary.remainingPercent > 0 || fallbackWindows.isEmpty {
            return primary
        }
        return fallbackWindows.first
    }

    public func orderedPerplexityDisplayWindows() -> [RateWindow] {
        let fallbackWindows = self.orderedPerplexityFallbackWindows()
        guard let primary = self.primary else {
            return fallbackWindows
        }
        if primary.remainingPercent > 0 || fallbackWindows.isEmpty {
            return [primary] + fallbackWindows
        }
        return fallbackWindows + [primary]
    }

    public func switcherWeeklyWindow(for provider: UsageProvider, showUsed: Bool) -> RateWindow? {
        switch provider {
        case .factory:
            // Factory prefers secondary window
            return self.secondary ?? self.primary
        case .perplexity:
            return self.automaticPerplexityWindow()
        case .cursor:
            // Cursor: fall back to on-demand budget when the included plan is exhausted (only in
            // "show remaining" mode). The secondary/tertiary lanes are Total/Auto/API breakdowns,
            // not extra capacity, so they should not replace the remaining paid quota indicator.
            if !showUsed,
               let primary = self.primary,
               primary.remainingPercent <= 0,
               let providerCost = self.providerCost,
               providerCost.limit > 0
            {
                let usedPercent = max(0, min(100, (providerCost.used / providerCost.limit) * 100))
                return RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: providerCost.resetsAt,
                    resetDescription: nil)
            }
            return self.primary ?? self.secondary
        default:
            return self.primary ?? self.secondary
        }
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

    /// Keep this initializer-style copy in sync with UsageSnapshot fields so relabeling/scoping never drops data.
    public func withIdentity(_ identity: ProviderIdentitySnapshot?) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            tertiary: self.tertiary,
            extraRateWindows: self.extraRateWindows,
            providerCost: self.providerCost,
            zaiUsage: self.zaiUsage,
            minimaxUsage: self.minimaxUsage,
            openRouterUsage: self.openRouterUsage,
            cursorRequests: self.cursorRequests,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    public func scoped(to provider: UsageProvider) -> UsageSnapshot {
        guard let identity else { return self }
        let scopedIdentity = identity.scoped(to: provider)
        if scopedIdentity.providerID == identity.providerID { return self }
        return self.withIdentity(scopedIdentity)
    }

    private func orderedPerplexityFallbackWindows() -> [RateWindow] {
        let fallbackWindows = [self.tertiary, self.secondary].compactMap(\.self)
        let usableFallback = fallbackWindows.filter { $0.remainingPercent > 0 }
        let exhaustedFallback = fallbackWindows.filter { $0.remainingPercent <= 0 }
        return usableFallback + exhaustedFallback
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

private struct RPCRateLimitsErrorBody: Decodable {
    let email: String?
    let planType: String?
    let rateLimit: CodexUsageResponse.RateLimitDetails?
    let credits: CodexUsageResponse.CreditDetails?

    enum CodingKeys: String, CodingKey {
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
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

/// RPC helper used on background tasks; safe because we confine it to the owning task.
private final class CodexRPCClient: @unchecked Sendable {
    private static let log = CodexBarLog.logger(LogCategories.codexRPC)
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
        arguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server"],
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutLineContinuation = stdoutContinuation

        let resolvedExec = BinaryLocator.resolveCodexBinary(env: environment)
            ?? TTYCommandRunner.which(executable)

        guard let resolvedExec else {
            Self.log.warning("Codex RPC binary not found", metadata: ["binary": executable])
            throw RPCWireError.startFailed(
                "Codex CLI not found. Install with `npm i -g @openai/codex` (or bun) then relaunch CodexBar.")
        }
        var env = environment
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
            Self.log.debug("Codex RPC started", metadata: ["binary": resolvedExec])
        } catch {
            Self.log.warning("Codex RPC failed to start", metadata: ["error": error.localizedDescription])
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
            Self.log.debug("Codex RPC stopping")
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
    typealias CodexStatusFetcher = @Sendable ([String: String], Bool) async throws -> CodexStatusSnapshot

    private let environment: [String: String]
    private let codexStatusFetcher: CodexStatusFetcher

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(environment: environment) { environment, keepCLISessionsAlive in
            try await CodexStatusProbe(
                keepCLISessionsAlive: keepCLISessionsAlive,
                environment: environment)
                .fetch()
        }
    }

    init(
        environment: [String: String],
        codexStatusFetcher: @escaping CodexStatusFetcher)
    {
        self.environment = environment
        self.codexStatusFetcher = codexStatusFetcher
        LoginShellPathCache.shared.captureOnce()
    }

    public func loadLatestUsage(keepCLISessionsAlive: Bool = false) async throws -> UsageSnapshot {
        try await self.withFallback(
            primary: self.loadRPCUsage,
            secondary: { try await self.loadTTYUsage(keepCLISessionsAlive: keepCLISessionsAlive) })
    }

    private func loadRPCUsage() async throws -> UsageSnapshot {
        let rpc = try CodexRPCClient(environment: self.environment)
        defer { rpc.shutdown() }
        do {
            try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
            // The app-server answers on a single stdout stream, so keep requests
            // serialized to avoid starving one reader when multiple awaiters race
            // for the same pipe.
            let limits = try await rpc.fetchRateLimits().rateLimits
            let account = try? await rpc.fetchAccount()
            let identity = ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: account?.account.flatMap { details in
                    if case let .chatgpt(email, _) = details { email } else { nil }
                },
                accountOrganization: nil,
                loginMethod: account?.account.flatMap { details in
                    if case let .chatgpt(_, plan) = details { plan } else { nil }
                })
            guard let state = CodexReconciledState.fromCLI(
                primary: Self.makeWindow(from: limits.primary),
                secondary: Self.makeWindow(from: limits.secondary),
                identity: identity)
            else {
                throw UsageError.noRateLimitsFound
            }
            return state.toUsageSnapshot()
        } catch {
            if let snapshot = Self.recoverUsageFromRPCError(error) {
                return snapshot
            }
            throw error
        }
    }

    private func loadTTYUsage(keepCLISessionsAlive: Bool) async throws -> UsageSnapshot {
        do {
            let status = try await self.codexStatusFetcher(self.environment, keepCLISessionsAlive)
            guard let state = CodexReconciledState.fromCLI(
                primary: Self.makeTTYWindow(
                    percentLeft: status.fiveHourPercentLeft,
                    windowMinutes: 300,
                    resetsAt: status.fiveHourResetsAt,
                    resetDescription: status.fiveHourResetDescription),
                secondary: Self.makeTTYWindow(
                    percentLeft: status.weeklyPercentLeft,
                    windowMinutes: 10080,
                    resetsAt: status.weeklyResetsAt,
                    resetDescription: status.weeklyResetDescription),
                identity: nil)
            else {
                throw UsageError.noRateLimitsFound
            }
            return state.toUsageSnapshot()
        } catch {
            throw error
        }
    }

    public func loadLatestCredits(keepCLISessionsAlive: Bool = false) async throws -> CreditsSnapshot {
        try await self.withFallback(
            primary: self.loadRPCCredits,
            secondary: { try await self.loadTTYCredits(keepCLISessionsAlive: keepCLISessionsAlive) })
    }

    private func loadRPCCredits() async throws -> CreditsSnapshot {
        let rpc = try CodexRPCClient(environment: self.environment)
        defer { rpc.shutdown() }
        do {
            try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
            let limits = try await rpc.fetchRateLimits().rateLimits
            guard let credits = limits.credits else { throw UsageError.noRateLimitsFound }
            let remaining = Self.parseCredits(credits.balance)
            return CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
        } catch {
            if let credits = Self.recoverCreditsFromRPCError(error) {
                return credits
            }
            throw error
        }
    }

    private func loadTTYCredits(keepCLISessionsAlive: Bool) async throws -> CreditsSnapshot {
        do {
            let status = try await self.codexStatusFetcher(self.environment, keepCLISessionsAlive)
            guard let credits = status.credits else { throw UsageError.noRateLimitsFound }
            return CreditsSnapshot(remaining: credits, events: [], updatedAt: Date())
        } catch {
            throw error
        }
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
            let rpc = try CodexRPCClient(environment: self.environment)
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
        let account = self.loadAuthBackedCodexAccount()
        return AccountInfo(email: account.email, plan: account.plan)
    }

    public func loadAuthBackedCodexAccount() -> CodexAuthBackedAccount {
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: self.environment) else {
            return CodexAuthBackedAccount(identity: .unresolved, email: nil, plan: nil)
        }

        let payload = credentials.idToken.flatMap(Self.parseJWT)
        let authDict = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = payload?["https://api.openai.com/profile"] as? [String: Any]

        let email = Self.normalizedCodexAccountField(
            (payload?["email"] as? String) ?? (profileDict?["email"] as? String))
        let plan = Self.normalizedCodexAccountField(
            (authDict?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String))
        let accountId = Self.normalizedCodexAccountField(
            credentials.accountId
                ?? (authDict?["chatgpt_account_id"] as? String)
                ?? (payload?["chatgpt_account_id"] as? String))
        let identity = CodexIdentityResolver.resolve(accountId: accountId, email: email)

        return CodexAuthBackedAccount(identity: identity, email: email, plan: plan)
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

    private static func makeWindow(from response: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let response else { return nil }
        let resetsAtDate = Date(timeIntervalSince1970: TimeInterval(response.resetAt))
        return RateWindow(
            usedPercent: Double(response.usedPercent),
            windowMinutes: response.limitWindowSeconds / 60,
            resetsAt: resetsAtDate,
            resetDescription: UsageFormatter.resetDescription(from: resetsAtDate))
    }

    private static func makeTTYWindow(
        percentLeft: Int?,
        windowMinutes: Int,
        resetsAt: Date?,
        resetDescription: String?) -> RateWindow?
    {
        guard let percentLeft else { return nil }
        return RateWindow(
            usedPercent: max(0, 100 - Double(percentLeft)),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private static func parseCredits(_ balance: String?) -> Double {
        guard let balance, let val = Double(balance) else { return 0 }
        return val
    }

    private static func recoverUsageFromRPCError(_ error: Error) -> UsageSnapshot? {
        guard let body = self.decodeRateLimitsErrorBody(from: error) else { return nil }
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: self.normalizedCodexAccountField(body.email),
            accountOrganization: nil,
            loginMethod: self.normalizedCodexAccountField(body.planType))
        guard let state = CodexReconciledState.fromCLI(
            primary: self.makeWindow(from: body.rateLimit?.primaryWindow),
            secondary: self.makeWindow(from: body.rateLimit?.secondaryWindow),
            identity: identity)
        else {
            return nil
        }
        if body.rateLimit?.hasWindowDecodeFailure == true,
           state.session == nil
        {
            return nil
        }
        return state.toUsageSnapshot()
    }

    private static func recoverCreditsFromRPCError(_ error: Error) -> CreditsSnapshot? {
        guard let credits = self.decodeRateLimitsErrorBody(from: error)?.credits else { return nil }
        guard let remaining = credits.balance else { return nil }
        return CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
    }

    private static func decodeRateLimitsErrorBody(from error: Error) -> RPCRateLimitsErrorBody? {
        guard case let RPCWireError.requestFailed(message) = error else { return nil }
        guard let json = self.extractJSONObject(after: "body=", in: message) else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RPCRateLimitsErrorBody.self, from: data)
    }

    private static func extractJSONObject(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false

        for index in suffix[start...].indices {
            let character = suffix[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[start...index])
                }
            default:
                break
            }
        }

        return nil
    }

    private static func normalizedCodexAccountField(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
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

#if DEBUG
extension UsageFetcher {
    static func _mapCodexRPCLimitsForTesting(
        primary: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?)?,
        secondary: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?)?) throws -> UsageSnapshot
    {
        guard let state = CodexReconciledState.fromCLI(
            primary: primary.map(self.makeTestingWindow),
            secondary: secondary.map(self.makeTestingWindow),
            identity: nil)
        else {
            throw UsageError.noRateLimitsFound
        }
        return state.toUsageSnapshot()
    }

    static func _mapCodexStatusForTesting(_ status: CodexStatusSnapshot) throws -> UsageSnapshot {
        guard let state = CodexReconciledState.fromCLI(
            primary: self.makeTTYWindow(
                percentLeft: status.fiveHourPercentLeft,
                windowMinutes: 300,
                resetsAt: status.fiveHourResetsAt,
                resetDescription: status.fiveHourResetDescription),
            secondary: self.makeTTYWindow(
                percentLeft: status.weeklyPercentLeft,
                windowMinutes: 10080,
                resetsAt: status.weeklyResetsAt,
                resetDescription: status.weeklyResetDescription),
            identity: nil)
        else {
            throw UsageError.noRateLimitsFound
        }
        return state.toUsageSnapshot()
    }

    public static func _recoverCodexRPCUsageFromErrorForTesting(_ message: String) -> UsageSnapshot? {
        self.recoverUsageFromRPCError(RPCWireError.requestFailed(message))
    }

    public static func _recoverCodexRPCCreditsFromErrorForTesting(_ message: String) -> CreditsSnapshot? {
        self.recoverCreditsFromRPCError(RPCWireError.requestFailed(message))
    }

    private static func makeTestingWindow(
        _ value: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?))
        -> RateWindow
    {
        let resetsAt = value.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateWindow(
            usedPercent: value.usedPercent,
            windowMinutes: value.windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { UsageFormatter.resetDescription(from: $0) })
    }
}
#endif
