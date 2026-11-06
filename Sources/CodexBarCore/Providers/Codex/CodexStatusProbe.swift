import Foundation

public struct CodexStatusSnapshot: Sendable {
    public let credits: Double?
    public let fiveHourPercentLeft: Int?
    public let weeklyPercentLeft: Int?
    public let fiveHourResetDescription: String?
    public let weeklyResetDescription: String?
    public let fiveHourResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let codexCreditLimit: CodexCreditLimitSnapshot?
    public let rawText: String

    public init(
        credits: Double?,
        fiveHourPercentLeft: Int?,
        weeklyPercentLeft: Int?,
        fiveHourResetDescription: String?,
        weeklyResetDescription: String?,
        fiveHourResetsAt: Date?,
        weeklyResetsAt: Date?,
        codexCreditLimit: CodexCreditLimitSnapshot? = nil,
        rawText: String)
    {
        self.credits = credits
        self.fiveHourPercentLeft = fiveHourPercentLeft
        self.weeklyPercentLeft = weeklyPercentLeft
        self.fiveHourResetDescription = fiveHourResetDescription
        self.weeklyResetDescription = weeklyResetDescription
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.codexCreditLimit = codexCreditLimit
        self.rawText = rawText
    }
}

public enum CodexStatusProbeError: LocalizedError, Sendable {
    case codexNotInstalled
    case launchBlocked(String)
    case parseFailed(String)
    case timedOut
    case updateRequired(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            "Codex CLI missing. Install via `npm i -g @openai/codex` (or bun install) and restart."
        case let .launchBlocked(message):
            message
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
    @ProcessEnvironment public var environment: [String: String] = ProcessInfo.processInfo.environment

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
        guard let resolved = TTYCommandRunner.which(self.codexBinary, environment: self.environment) else {
            throw CodexStatusProbeError.codexNotInstalled
        }
        if let message = CodexCLILaunchGate.shared.backgroundSkipMessage(binary: resolved) {
            throw CodexStatusProbeError.launchBlocked(message)
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
        } catch {
            throw error
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
        let monthlyLimit = self.parseMonthlyCreditLimit(text: clean, now: now)
        if credits == nil, fivePct == nil, weekPct == nil, monthlyLimit == nil {
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
            codexCreditLimit: monthlyLimit,
            rawText: clean)
    }

    private static func parseMonthlyCreditLimit(text: String, now: Date) -> CodexCreditLimitSnapshot? {
        guard let monthlyLine = TextParsing.firstLine(matching: #"Monthly credit limit[^\n]*"#, text: text) else {
            return nil
        }
        guard let limit = TextParsing.firstNumber(
            pattern: #"of\s+([0-9][0-9., ]*)\s+credits used"#,
            text: text),
            limit > 0
        else {
            return nil
        }
        let used = TextParsing.firstNumber(
            pattern: #"([0-9][0-9., ]*)\s+of\s+[0-9][0-9., ]*\s+credits used"#,
            text: text) ?? 0
        let remainingPercent = TextParsing.percentLeft(fromLine: monthlyLine)
            .map(Double.init)
            ?? max(0, min(100, 100 - (used / limit * 100)))
        let resetText = TextParsing.resetString(fromLine: monthlyLine)
        return CodexCreditLimitSnapshot(
            used: used,
            limit: limit,
            remainingPercent: remainingPercent,
            resetsAt: self.parseResetDate(from: resetText, now: now),
            updatedAt: now)
    }

    static func parseResetDate(
        from text: String?,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)) -> Date?
    {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
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

        // Parse the clock independently of any daylight-saving gap on today's date.
        formatter.defaultDate = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))
        for format in ["HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: raw) {
                let clock = calendar.dateComponents([.hour, .minute], from: time)
                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.hour = clock.hour
                components.minute = clock.minute
                guard let anchored = calendar.date(from: components) else { return nil }
                if anchored >= now {
                    return anchored
                }
                components.day = calendar.component(.day, from: now) + 1
                return calendar.date(from: components)
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
        let stateHome = try CodexStatusProbeIsolation.supportDirectory(environment: self.environment)
        let extraArgs = CodexStatusProbeIsolation.codexArguments(stateHome: stateHome)
        let workingDirectory = CodexStatusProbeIsolation.workingDirectory(environment: self.environment)
        let text: String
        if self.keepCLISessionsAlive {
            do {
                text = try await CodexCLISession.shared.captureStatus(
                    binary: binary,
                    options: .init(
                        timeout: timeout,
                        rows: rows,
                        cols: cols,
                        environment: self.environment,
                        extraArgs: extraArgs,
                        workingDirectory: workingDirectory))
            } catch CodexCLISession.SessionError.processExited {
                throw CodexStatusProbeError.timedOut
            } catch CodexCLISession.SessionError.timedOut {
                throw CodexStatusProbeError.timedOut
            } catch let CodexCLISession.SessionError.launchFailed(message) {
                if let throttled = CodexCLILaunchGate.shared.recordLaunchFailure(binary: binary, message: message) {
                    throw CodexStatusProbeError.launchBlocked(throttled)
                }
                throw CodexStatusProbeError.codexNotInstalled
            }
        } else {
            let runner = TTYCommandRunner()
            let script = "/status"
            let result: TTYCommandRunner.Result
            do {
                result = try runner.run(
                    binary: binary,
                    send: script,
                    options: .init(
                        rows: rows,
                        cols: cols,
                        timeout: timeout,
                        workingDirectory: workingDirectory,
                        extraArgs: extraArgs,
                        baseEnvironment: self.environment,
                        forceCodexStatusMode: true))
            } catch let TTYCommandRunner.Error.launchFailed(message) {
                if let throttled = CodexCLILaunchGate.shared.recordLaunchFailure(binary: binary, message: message) {
                    throw CodexStatusProbeError.launchBlocked(throttled)
                }
                throw CodexStatusProbeError.codexNotInstalled
            }
            text = result.text
        }
        return try Self.parse(text: text)
    }

    private static func containsUpdatePrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("update available") && lower.contains("codex")
    }
}
