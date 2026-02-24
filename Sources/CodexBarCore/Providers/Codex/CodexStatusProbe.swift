import Foundation

public struct CodexStatusSnapshot: Sendable {
    public let credits: Double?
    public let fiveHourPercentLeft: Int?
    public let weeklyPercentLeft: Int?
    public let fiveHourResetDescription: String?
    public let weeklyResetDescription: String?
    public let rawText: String

    public init(
        credits: Double?,
        fiveHourPercentLeft: Int?,
        weeklyPercentLeft: Int?,
        fiveHourResetDescription: String?,
        weeklyResetDescription: String?,
        rawText: String)
    {
        self.credits = credits
        self.fiveHourPercentLeft = fiveHourPercentLeft
        self.weeklyPercentLeft = weeklyPercentLeft
        self.fiveHourResetDescription = fiveHourResetDescription
        self.weeklyResetDescription = weeklyResetDescription
        self.rawText = rawText
    }
}

public enum CodexStatusProbeError: LocalizedError, Sendable {
    case codexNotInstalled
    case parseFailed(String)
    case timedOut
    case updateRequired(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            "Codex CLI missing. Install via `npm i -g @openai/codex` (or bun install) and restart."
        case .parseFailed:
            "Could not parse Codex status; will retry shortly."
        case .timedOut:
            "Codex status probe timed out."
        case let .updateRequired(msg):
            "Codex CLI update needed: \(msg)"
        }
    }
}

/// Runs `codex` inside a PTY, sends `/status`, captures text, and parses credits/limits.
public struct CodexStatusProbe {
    private static let defaultTimeoutSeconds: TimeInterval = 8.0
    private static let parseRetryTimeoutSeconds: TimeInterval = 4.0

    public var codexBinary: String = "codex"
    public var timeout: TimeInterval = Self.defaultTimeoutSeconds
    public var keepCLISessionsAlive: Bool = false

    public init() {}

    public init(
        codexBinary: String = "codex",
        timeout: TimeInterval = 8.0,
        keepCLISessionsAlive: Bool = false)
    {
        self.codexBinary = codexBinary
        self.timeout = timeout
        self.keepCLISessionsAlive = keepCLISessionsAlive
    }

    public func fetch() async throws -> CodexStatusSnapshot {
        let env = ProcessInfo.processInfo.environment
        let resolved = BinaryLocator.resolveCodexBinary(env: env, loginPATH: LoginShellPathCache.shared.current)
            ?? self.codexBinary
        guard FileManager.default.isExecutableFile(atPath: resolved) || TTYCommandRunner.which(resolved) != nil else {
            throw CodexStatusProbeError.codexNotInstalled
        }
        do {
            return try await self.runAndParse(binary: resolved, rows: 60, cols: 200, timeout: self.timeout)
        } catch let error as CodexStatusProbeError {
            // Retry only parser-level flakes with a short second attempt.
            switch error {
            case .parseFailed:
                return try await self.runAndParse(
                    binary: resolved,
                    rows: 70,
                    cols: 220,
                    timeout: Self.parseRetryTimeoutSeconds)
            default:
                throw error
            }
        }
    }

    // MARK: - Parsing

    public static func parse(text: String) throws -> CodexStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        guard !clean.isEmpty else { throw CodexStatusProbeError.timedOut }
        if clean.localizedCaseInsensitiveContains("data not available yet") {
            throw CodexStatusProbeError.parseFailed("data not available yet")
        }
        if self.containsUpdatePrompt(clean) {
            throw CodexStatusProbeError.updateRequired(
                "Run `bun install -g @openai/codex` to continue (update prompt blocking /status).")
        }
        let credits = TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9.,]*)"#, text: clean)
        // Pull reset info from the same lines that contain the percentages.
        let fiveLine = TextParsing.firstLine(matching: #"5h limit[^\n]*"#, text: clean)
        let weekLine = TextParsing.firstLine(matching: #"Weekly limit[^\n]*"#, text: clean)
        let fivePct = fiveLine.flatMap(TextParsing.percentLeft(fromLine:))
        let weekPct = weekLine.flatMap(TextParsing.percentLeft(fromLine:))
        let fiveReset = fiveLine.flatMap(TextParsing.resetString(fromLine:))
        let weekReset = weekLine.flatMap(TextParsing.resetString(fromLine:))
        if credits == nil, fivePct == nil, weekPct == nil {
            throw CodexStatusProbeError.parseFailed(clean.prefix(400).description)
        }
        return CodexStatusSnapshot(
            credits: credits,
            fiveHourPercentLeft: fivePct,
            weeklyPercentLeft: weekPct,
            fiveHourResetDescription: fiveReset,
            weeklyResetDescription: weekReset,
            rawText: clean)
    }

    private func runAndParse(
        binary: String,
        rows: UInt16,
        cols: UInt16,
        timeout: TimeInterval) async throws -> CodexStatusSnapshot
    {
        let text: String
        if self.keepCLISessionsAlive {
            do {
                text = try await CodexCLISession.shared.captureStatus(
                    binary: binary,
                    timeout: timeout,
                    rows: rows,
                    cols: cols)
            } catch CodexCLISession.SessionError.processExited {
                throw CodexStatusProbeError.timedOut
            } catch CodexCLISession.SessionError.timedOut {
                throw CodexStatusProbeError.timedOut
            } catch CodexCLISession.SessionError.launchFailed(_) {
                throw CodexStatusProbeError.codexNotInstalled
            }
        } else {
            let runner = TTYCommandRunner()
            let script = "/status\n"
            let result = try runner.run(
                binary: binary,
                send: script,
                options: .init(
                    rows: rows,
                    cols: cols,
                    timeout: timeout,
                    extraArgs: ["-s", "read-only", "-a", "untrusted"]))
            text = result.text
        }
        return try Self.parse(text: text)
    }

    private static func containsUpdatePrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("update available") && lower.contains("codex")
    }
}
