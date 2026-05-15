import Foundation

/// JSON-RPC client for `grok agent stdio` (ACP protocol).
///
/// The protocol mirrors Codex's app-server (newline-delimited JSON-RPC 2.0 over stdin/stdout),
/// but uses `protocolVersion`/`clientCapabilities` for the `initialize` call instead of
/// `clientInfo`. Billing is fetched via the `x.ai/billing` extension method.
final class GrokRPCClient: @unchecked Sendable {
    private static let log = CodexBarLog.logger(LogCategories.grok)

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let initializeTimeoutSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private var nextID: Int = 1
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation

    init(
        executable: String = "grok",
        arguments: [String] = ["agent", "stdio"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        initializeTimeoutSeconds: TimeInterval = 8.0,
        requestTimeoutSeconds: TimeInterval = 12.0) throws
    {
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutLineContinuation = stdoutContinuation

        let resolvedExec = BinaryLocator.resolveGrokBinary(env: environment)
            ?? TTYCommandRunner.which(executable)

        guard let resolvedExec else {
            Self.log.warning("Grok RPC binary not found", metadata: ["binary": executable])
            throw GrokRPCError.binaryNotFound
        }

        var env = environment
        env["PATH"] = PathBuilder.effectivePATH(purposes: [.rpc], env: env)

        self.process.environment = env
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = [resolvedExec] + arguments
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
            Self.log.debug("Grok RPC started", metadata: ["binary": resolvedExec])
        } catch {
            Self.log.warning("Grok RPC failed to start", metadata: ["error": error.localizedDescription])
            throw GrokRPCError.startFailed(error.localizedDescription)
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
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                #if !os(Linux)
                fputs("[grok stderr] \(line)\n", stderr)
                #endif
            }
        }
    }

    deinit {
        self.shutdown()
    }

    func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "1",
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
        ]
        _ = try await self.request(
            method: "initialize",
            params: params,
            timeout: self.initializeTimeoutSeconds)
    }

    /// Calls `x.ai/billing` and returns the decoded response.
    func fetchBilling() async throws -> GrokBillingResponse {
        let message = try await self.request(method: "x.ai/billing", params: [:])
        return try self.decodeResult(from: message)
    }

    func shutdown() {
        if self.process.isRunning {
            Self.log.debug("Grok RPC stopping")
            self.process.terminate()
        }
    }

    // MARK: - JSON-RPC plumbing (mirrors CodexRPCClient)

    private struct SendableJSONMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval? = nil) async throws -> [String: Any]
    {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        let resolvedTimeout = timeout ?? self.requestTimeoutSeconds
        let wrapped = try await self.withTimeout(seconds: resolvedTimeout, method: method) {
            while true {
                let message = try await self.readNextMessage()
                // Skip notifications (no id) or unrelated responses.
                if message["id"] == nil { continue }
                guard let messageID = self.jsonID(message["id"]), messageID == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    let messageText = (error["message"] as? String) ?? "unknown JSON-RPC error"
                    throw GrokRPCError.requestFailed(messageText)
                }
                return SendableJSONMessage(value: message)
            }
        }
        return wrapped.value
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        body: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                self?.terminateProcessForTimeout(method: method)
                throw GrokRPCError.timeout(method: method)
            }
            do {
                guard let result = try await group.next() else {
                    throw GrokRPCError.timeout(method: method)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func terminateProcessForTimeout(method: String) {
        if self.process.isRunning {
            Self.log.warning("Grok RPC timed out on `\(method)`; terminating process")
            self.process.terminate()
        }
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        let paramsValue: Any = params ?? [:]
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": paramsValue,
        ]
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
        throw GrokRPCError.malformed("grok agent stdio closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw GrokRPCError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: int
        case let number as NSNumber: number.intValue
        default: nil
        }
    }

    private final class LineBuffer: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()

        func appendAndDrainLines(_ data: Data) -> [Data] {
            self.lock.lock()
            defer { lock.unlock() }
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
}

public enum GrokRPCError: LocalizedError, Sendable {
    case binaryNotFound
    case startFailed(String)
    case requestFailed(String)
    case timeout(method: String)
    case malformed(String)
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Grok CLI not found. Install via `curl -fsSL https://x.ai/cli/install.sh | bash`."
        case let .startFailed(message):
            return "Grok CLI failed to start: \(message)"
        case let .requestFailed(message):
            // Surface the auth-required hint that billing.rs emits verbatim.
            if message.localizedCaseInsensitiveContains("authentication required")
                || message.localizedCaseInsensitiveContains("grok login")
            {
                return "Grok billing requires authentication. Run `grok login`."
            }
            return "Grok request failed: \(message)"
        case let .timeout(method):
            return "Grok RPC timed out on `\(method)`."
        case let .malformed(message):
            return "Malformed Grok RPC response: \(message)"
        case .notAuthenticated:
            return "Not authenticated to Grok. Run `grok login`."
        }
    }
}

/// Schema for the `x.ai/billing` result.
///
/// All monetary amounts (`monthlyLimit`, `onDemandCap`, `includedUsed`, etc.) are
/// represented as `{ val: <cents> }` in the wire format.
public struct GrokBillingResponse: Codable, Sendable {
    public let billingCycle: GrokBillingCycle?
    public let monthlyLimit: GrokCent?
    public let onDemandCap: GrokCent?
    public let onDemandEnabled: Bool?
    public let disabledByConfig: Bool?
    public let usage: GrokBillingUsage?

    private enum CodingKeys: String, CodingKey {
        case billingCycle
        case monthlyLimit
        case onDemandCap
        case onDemandEnabled = "on_demand_enabled"
        case disabledByConfig
        case usage
    }
}

public struct GrokBillingCycle: Codable, Sendable {
    public let billingPeriodStart: String?
    public let billingPeriodEnd: String?
}

public struct GrokBillingUsage: Codable, Sendable {
    public let includedUsed: GrokCent?
    public let onDemandUsed: GrokCent?
    public let totalUsed: GrokCent?
}

public struct GrokCent: Codable, Sendable {
    public let val: Int?
}

extension GrokBillingResponse {
    /// Convenience accessor: monthly usage as a 0–100 percent.
    public var monthlyUsedPercent: Double? {
        guard let limit = self.monthlyLimit?.val, limit > 0,
              let used = self.usage?.totalUsed?.val
        else { return nil }
        return min(100.0, max(0.0, Double(used) / Double(limit) * 100.0))
    }

    public var billingPeriodEndDate: Date? {
        guard let raw = self.billingCycle?.billingPeriodEnd else { return nil }
        return GrokBillingResponse.parseISO8601(raw)
    }

    public var billingPeriodStartDate: Date? {
        guard let raw = self.billingCycle?.billingPeriodStart else { return nil }
        return GrokBillingResponse.parseISO8601(raw)
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
