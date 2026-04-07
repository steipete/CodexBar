import Foundation

public struct CodexStatusSnapshot: Sendable {
    public let credits: Double?
    public let fiveHourPercentLeft: Int?
    public let weeklyPercentLeft: Int?
    public let fiveHourResetDescription: String?
    public let weeklyResetDescription: String?
    public let fiveHourResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let rawText: String

    public init(
        credits: Double?,
        fiveHourPercentLeft: Int?,
        weeklyPercentLeft: Int?,
        fiveHourResetDescription: String?,
        weeklyResetDescription: String?,
        fiveHourResetsAt: Date?,
        weeklyResetsAt: Date?,
        rawText: String)
    {
        self.credits = credits
        self.fiveHourPercentLeft = fiveHourPercentLeft
        self.weeklyPercentLeft = weeklyPercentLeft
        self.fiveHourResetDescription = fiveHourResetDescription
        self.weeklyResetDescription = weeklyResetDescription
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
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
    public var environment: [String: String] = ProcessInfo.processInfo.environment

    public init() {}

    public init(
        codexBinary: String = "codex",
        timeout: TimeInterval = 8.0,
        keepCLISessionsAlive: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.codexBinary = codexBinary
        self.timeout = timeout
        self.keepCLISessionsAlive = keepCLISessionsAlive
        self.environment = environment
    }

    public func fetch() async throws -> CodexStatusSnapshot {
        let env = self.environment
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

    public static func parse(text: String, now: Date = .init()) throws -> CodexStatusSnapshot {
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
            fiveHourResetsAt: self.parseResetDate(from: fiveReset, now: now),
            weeklyResetsAt: self.parseResetDate(from: weekReset, now: now),
            rawText: clean)
    }

    private static func parseResetDate(from text: String?, now: Date) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.defaultDate = now

        if let match = raw.firstMatch(of: /^([0-9]{1,2}:[0-9]{2}) on ([0-9]{1,2} [A-Za-z]{3})$/) {
            raw = "\(match.output.2) \(match.output.1)"
            formatter.dateFormat = "d MMM HH:mm"
            if let date = formatter.date(from: raw) {
                return self.bumpYearIfNeeded(date, now: now, calendar: calendar)
            }
        }

        if let match = raw.firstMatch(of: /^([0-9]{1,2}:[0-9]{2}) on ([A-Za-z]{3} [0-9]{1,2})$/) {
            raw = "\(match.output.2) \(match.output.1)"
            formatter.dateFormat = "MMM d HH:mm"
            if let date = formatter.date(from: raw) {
                return self.bumpYearIfNeeded(date, now: now, calendar: calendar)
            }
        }

        for format in ["HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: raw) {
                let components = calendar.dateComponents([.hour, .minute], from: time)
                guard let anchored = calendar.date(
                    bySettingHour: components.hour ?? 0,
                    minute: components.minute ?? 0,
                    second: 0,
                    of: now)
                else {
                    return nil
                }
                if anchored >= now {
                    return anchored
                }
                return calendar.date(byAdding: .day, value: 1, to: anchored)
            }
        }

        return nil
    }

    private static func bumpYearIfNeeded(_ date: Date, now: Date, calendar: Calendar) -> Date? {
        if date >= now {
            return date
        }
        return calendar.date(byAdding: .year, value: 1, to: date)
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
                    cols: cols,
                    environment: self.environment)
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
                    extraArgs: ["-s", "read-only", "-a", "untrusted"],
                    baseEnvironment: self.environment))
            text = result.text
        }
        return try Self.parse(text: text)
    }

    private static func containsUpdatePrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("update available") && lower.contains("codex")
    }
}
