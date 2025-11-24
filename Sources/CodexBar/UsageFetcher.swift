import Foundation

struct RateWindow: Codable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    let resetDescription: String?

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

struct UsageSnapshot {
    let primary: RateWindow
    let secondary: RateWindow
    let tertiary: RateWindow?
    let updatedAt: Date
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?

    init(
        primary: RateWindow,
        secondary: RateWindow,
        tertiary: RateWindow? = nil,
        updatedAt: Date,
        accountEmail: String? = nil,
        accountOrganization: String? = nil,
        loginMethod: String? = nil)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.updatedAt = updatedAt
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
    }
}

struct AccountInfo: Equatable {
    let email: String?
    let plan: String?
}

enum UsageError: LocalizedError {
    case noSessions
    case noRateLimitsFound
    case decodeFailed

    var errorDescription: String? {
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

private enum RPCWireError: Error, CustomStringConvertible {
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)

    var description: String {
        switch self {
        case let .startFailed(message):
            "Failed to start codex app-server: \(message)"
        case let .requestFailed(message):
            "RPC request failed: \(message)"
        case let .malformed(message):
            "Malformed response: \(message)"
        }
    }
}

// RPC helper used on background tasks; safe because we confine it to the owning task.
private final class CodexRPCClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var nextID = 1

    init(
        executable: String = "codex",
        arguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server"]) throws
    {
        let resolvedExec = TTYCommandRunner.which(executable) ?? executable
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.seededPATH(from: env)

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
                fputs("[codex stderr] \(line)\n", stderr)
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
                fputs("[codex notify] \(methodName)\n", stderr)
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
        for try await lineData in self.stdoutPipe.fileHandleForReading.bytes.lines {
            if lineData.isEmpty { continue }
            let line = String(lineData)
            guard let data = line.data(using: .utf8) else { continue }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
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

    /// Builds a PATH that works in hardened contexts by appending common install locations (Homebrew, bun, nvm, npm).
    static func seededPATH(from env: [String: String]) -> String {
        let home = NSHomeDirectory()
        let nvmVersionsDir = "\(home)/.nvm/versions/node"
        let nvmBins: [String] = if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir) {
            versions.map { "\(nvmVersionsDir)/\($0)/bin" }
        } else {
            []
        }
        let defaultPath = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/share/fnm",
            "\(home)/.fnm",
        ] + nvmBins
        let joined = defaultPath.joined(separator: ":")
        if let existing = env["PATH"], !existing.isEmpty {
            return "\(existing):\(joined)"
        }
        return joined
    }
}

// MARK: - Public fetcher used by the app

struct UsageFetcher: Sendable {
    private let environment: [String: String]

    /// Builds a PATH that works in hardened contexts by appending common install locations (Homebrew, bun, nvm, fnm,
    /// npm).
    static func seededPATH(from env: [String: String]) -> String {
        let home = NSHomeDirectory()
        let nvmVersionsDir = "\(home)/.nvm/versions/node"
        let nvmBins: [String] = if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDir) {
            versions.map { "\(nvmVersionsDir)/\($0)/bin" }
        } else {
            []
        }
        let defaultPath = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/share/fnm",
            "\(home)/.fnm",
        ] + nvmBins
        let joined = defaultPath.joined(separator: ":")
        if let existing = env["PATH"], !existing.isEmpty {
            return "\(existing):\(joined)"
        }
        return joined
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func loadLatestUsage() async throws -> UsageSnapshot {
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

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            accountEmail: account?.account.flatMap { details in
                if case let .chatgpt(email, _) = details { email } else { nil }
            },
            accountOrganization: nil,
            loginMethod: account?.account.flatMap { details in
                if case let .chatgpt(_, plan) = details { plan } else { nil }
            })
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
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
    }

    func loadLatestCredits() async throws -> CreditsSnapshot {
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

    func debugRawRateLimits() async -> String {
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

    func loadAccountInfo() -> AccountInfo {
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

    private static func parseJWT(_ token: String) -> [String: Any]? {
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
