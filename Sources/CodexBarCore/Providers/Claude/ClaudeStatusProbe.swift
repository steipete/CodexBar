import Foundation

public struct ClaudeStatusSnapshot: Sendable {
    public let sessionPercentLeft: Int?
    public let weeklyPercentLeft: Int?
    public let opusPercentLeft: Int?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let primaryResetDescription: String?
    public let secondaryResetDescription: String?
    public let opusResetDescription: String?
    public let rawText: String
}

public struct ClaudeAccountIdentity: Sendable {
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?

    public init(accountEmail: String?, accountOrganization: String?, loginMethod: String?) {
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
    }
}

public enum ClaudeStatusProbeError: LocalizedError, Sendable {
    case claudeNotInstalled
    case parseFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .claudeNotInstalled:
            "Claude CLI is not installed or not on PATH."
        case let .parseFailed(msg):
            "Could not parse Claude usage: \(msg)"
        case .timedOut:
            "Claude usage probe timed out."
        }
    }
}

/// Runs `claude` inside a PTY, sends `/usage`, and parses the rendered text panel.
public struct ClaudeStatusProbe: Sendable {
    public var claudeBinary: String = "claude"
    public var timeout: TimeInterval = 20.0
    public var keepCLISessionsAlive: Bool = false
    private static let log = CodexBarLog.logger(LogCategories.claudeProbe)

    public init(claudeBinary: String = "claude", timeout: TimeInterval = 20.0, keepCLISessionsAlive: Bool = false) {
        self.claudeBinary = claudeBinary
        self.timeout = timeout
        self.keepCLISessionsAlive = keepCLISessionsAlive
    }

    public func fetch() async throws -> ClaudeStatusSnapshot {
        let env = ProcessInfo.processInfo.environment
        let resolved = BinaryLocator.resolveClaudeBinary(env: env, loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which(self.claudeBinary)
            ?? self.claudeBinary
        guard FileManager.default.isExecutableFile(atPath: resolved) || TTYCommandRunner.which(resolved) != nil else {
            throw ClaudeStatusProbeError.claudeNotInstalled
        }

        // Run commands sequentially through a shared Claude session to avoid warm-up churn.
        let timeout = self.timeout
        let keepAlive = self.keepCLISessionsAlive
        do {
            let usage = try await Self.capture(subcommand: "/usage", binary: resolved, timeout: timeout)
            let status = try? await Self.capture(subcommand: "/status", binary: resolved, timeout: min(timeout, 12))
            let snap = try Self.parse(text: usage, statusText: status)

            Self.log.info("Claude CLI scrape ok", metadata: [
                "sessionPercentLeft": "\(snap.sessionPercentLeft ?? -1)",
                "weeklyPercentLeft": "\(snap.weeklyPercentLeft ?? -1)",
                "opusPercentLeft": "\(snap.opusPercentLeft ?? -1)",
            ])
            if !keepAlive {
                await ClaudeCLISession.shared.reset()
            }
            return snap
        } catch {
            if !keepAlive {
                await ClaudeCLISession.shared.reset()
            }
            throw error
        }
    }

    // MARK: - Parsing helpers

    private struct LabelSearchContext {
        let lines: [String]
        let normalizedLines: [String]
        let normalizedData: Data

        init(text: String) {
            self.lines = text.components(separatedBy: .newlines)
            self.normalizedLines = self.lines.map { ClaudeStatusProbe.normalizedForLabelSearch($0) }
            let normalized = ClaudeStatusProbe.normalizedForLabelSearch(text)
            self.normalizedData = Data(normalized.utf8)
        }

        func contains(_ needle: Data) -> Bool {
            self.normalizedData.range(of: needle) != nil
        }
    }

    private static let weeklyLabelNeedle = Data("current week".utf8)
    private static let opusLabelNeedle = Data("opus".utf8)
    private static let sonnetLabelNeedle = Data("sonnet".utf8)

    public static func parse(text: String, statusText: String? = nil) throws -> ClaudeStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        let statusClean = statusText.map(TextParsing.stripANSICodes)
        guard !clean.isEmpty else { throw ClaudeStatusProbeError.timedOut }

        let shouldDump = ProcessInfo.processInfo.environment["DEBUG_CLAUDE_DUMP"] == "1"

        if let usageError = self.extractUsageError(text: clean) {
            Self.dumpIfNeeded(
                enabled: shouldDump,
                reason: "usageError: \(usageError)",
                usage: clean,
                status: statusText)
            throw ClaudeStatusProbeError.parseFailed(usageError)
        }

        let labelContext = LabelSearchContext(text: clean)

        var sessionPct = self.extractPercent(labelSubstring: "Current session", context: labelContext)
        var weeklyPct = self.extractPercent(labelSubstring: "Current week (all models)", context: labelContext)
        var opusPct = self.extractPercent(
            labelSubstrings: [
                "Current week (Opus)",
                "Current week (Sonnet only)",
                "Current week (Sonnet)",
            ],
            context: labelContext)

        // Fallback: order-based percent scraping when labels are present but the surrounding layout moved.
        // Only apply the fallback when the corresponding label exists in the rendered panel; enterprise accounts
        // may omit the weekly panel entirely, and we should treat that as "unavailable" rather than guessing.
        let hasWeeklyLabel = labelContext.contains(Self.weeklyLabelNeedle)
        let hasOpusLabel = labelContext.contains(Self.opusLabelNeedle) || labelContext.contains(Self.sonnetLabelNeedle)

        if sessionPct == nil || (hasWeeklyLabel && weeklyPct == nil) || (hasOpusLabel && opusPct == nil) {
            let ordered = self.allPercents(clean)
            if sessionPct == nil, ordered.indices.contains(0) { sessionPct = ordered[0] }
            if hasWeeklyLabel, weeklyPct == nil, ordered.indices.contains(1) { weeklyPct = ordered[1] }
            if hasOpusLabel, opusPct == nil, ordered.indices.contains(2) { opusPct = ordered[2] }
        }

        let identity = Self.parseIdentity(usageText: clean, statusText: statusClean)

        guard let sessionPct else {
            Self.dumpIfNeeded(
                enabled: shouldDump,
                reason: "missing session label",
                usage: clean,
                status: statusText)
            throw ClaudeStatusProbeError.parseFailed("Missing Current session")
        }

        let sessionReset = self.extractReset(labelSubstring: "Current session", context: labelContext)
        let weeklyReset = hasWeeklyLabel
            ? self.extractReset(labelSubstring: "Current week (all models)", context: labelContext)
            : nil
        let opusReset = hasOpusLabel
            ? self.extractReset(
                labelSubstrings: [
                    "Current week (Opus)",
                    "Current week (Sonnet only)",
                    "Current week (Sonnet)",
                ],
                context: labelContext)
            : nil

        return ClaudeStatusSnapshot(
            sessionPercentLeft: sessionPct,
            weeklyPercentLeft: weeklyPct,
            opusPercentLeft: opusPct,
            accountEmail: identity.accountEmail,
            accountOrganization: identity.accountOrganization,
            loginMethod: identity.loginMethod,
            primaryResetDescription: sessionReset,
            secondaryResetDescription: weeklyReset,
            opusResetDescription: opusReset,
            rawText: text + (statusText ?? ""))
    }

    public static func parseIdentity(usageText: String?, statusText: String?) -> ClaudeAccountIdentity {
        let usageClean = usageText.map(TextParsing.stripANSICodes) ?? ""
        let statusClean = statusText.map(TextParsing.stripANSICodes)
        return self.extractIdentity(usageText: usageClean, statusText: statusClean)
    }

    public static func fetchIdentity(timeout: TimeInterval = 12.0) async throws -> ClaudeAccountIdentity {
        let env = ProcessInfo.processInfo.environment
        let resolved = BinaryLocator.resolveClaudeBinary(env: env, loginPATH: LoginShellPathCache.shared.current)
            ?? TTYCommandRunner.which("claude")
            ?? "claude"
        guard FileManager.default.isExecutableFile(atPath: resolved) || TTYCommandRunner.which(resolved) != nil else {
            throw ClaudeStatusProbeError.claudeNotInstalled
        }
        let statusText = try await Self.capture(subcommand: "/status", binary: resolved, timeout: timeout)
        return Self.parseIdentity(usageText: nil, statusText: statusText)
    }

    private static func extractPercent(labelSubstring: String, context: LabelSearchContext) -> Int? {
        let lines = context.lines
        let label = self.normalizedForLabelSearch(labelSubstring)
        for (idx, normalizedLine) in context.normalizedLines.enumerated() where normalizedLine.contains(label) {
            // Claude's usage panel can take a moment to render percentages (especially on enterprise accounts),
            // so scan a larger window than the original 3–4 lines.
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = self.percentFromLine(candidate) { return pct }
            }
        }
        return nil
    }

    private static func extractPercent(labelSubstrings: [String], context: LabelSearchContext) -> Int? {
        for label in labelSubstrings {
            if let value = self.extractPercent(labelSubstring: label, context: context) { return value }
        }
        return nil
    }

    private static func percentFromLine(_ line: String, assumeRemainingWhenUnclear: Bool = false) -> Int? {
        // Allow optional Unicode whitespace before % to handle CLI formatting changes.
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line)
        else { return nil }
        let rawVal = Double(line[valRange]) ?? 0
        let clamped = max(0, min(100, rawVal))
        let lower = line.lowercased()
        let usedKeywords = ["used", "spent", "consumed"]
        let remainingKeywords = ["left", "remaining", "available"]
        if usedKeywords.contains(where: lower.contains) {
            return Int(max(0, min(100, 100 - clamped)).rounded())
        }
        if remainingKeywords.contains(where: lower.contains) {
            return Int(clamped.rounded())
        }
        return assumeRemainingWhenUnclear ? Int(clamped.rounded()) : nil
    }

    private static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractIdentity(usageText: String, statusText: String?) -> ClaudeAccountIdentity {
        let emailPatterns = [
            #"(?i)Account:\s+([^\s@]+@[^\s@]+)"#,
            #"(?i)Email:\s+([^\s@]+@[^\s@]+)"#,
        ]
        let looseEmailPatterns = [
            #"(?i)Account:\s+(\S+)"#,
            #"(?i)Email:\s+(\S+)"#,
        ]
        let email = emailPatterns
            .compactMap { self.extractFirst(pattern: $0, text: usageText) }
            .first
            ?? emailPatterns
            .compactMap { self.extractFirst(pattern: $0, text: statusText ?? "") }
            .first
            ?? looseEmailPatterns
            .compactMap { self.extractFirst(pattern: $0, text: usageText) }
            .first
            ?? looseEmailPatterns
            .compactMap { self.extractFirst(pattern: $0, text: statusText ?? "") }
            .first
            ?? self.extractFirst(
                pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                text: usageText)
            ?? self.extractFirst(
                pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                text: statusText ?? "")
        let orgPatterns = [
            #"(?i)Org:\s*(.+)"#,
            #"(?i)Organization:\s*(.+)"#,
        ]
        let orgRaw = orgPatterns
            .compactMap { self.extractFirst(pattern: $0, text: usageText) }
            .first
            ?? orgPatterns
            .compactMap { self.extractFirst(pattern: $0, text: statusText ?? "") }
            .first
        let org: String? = {
            guard let orgText = orgRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !orgText.isEmpty else {
                return nil
            }
            // Suppress org if it’s just the email prefix (common in CLI panels).
            if let email, orgText.lowercased().hasPrefix(email.lowercased()) { return nil }
            return orgText
        }()
        // Prefer explicit login method from /status, then fall back to /usage header heuristics.
        let login = self.extractLoginMethod(text: statusText ?? "") ?? self.extractLoginMethod(text: usageText)
        return ClaudeAccountIdentity(accountEmail: email, accountOrganization: org, loginMethod: login)
    }

    private static func extractUsageError(text: String) -> String? {
        if let jsonHint = self.extractUsageErrorJSON(text: text) { return jsonHint }

        let lower = text.lowercased()
        if lower.contains("do you trust the files in this folder?"), !lower.contains("current session") {
            let folder = self.extractFirst(
                pattern: #"Do you trust the files in this folder\?\s*(?:\r?\n)+\s*([^\r\n]+)"#,
                text: text)
            let folderHint = folder.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let folderHint {
                return """
                Claude CLI is waiting for a folder trust prompt (\(folderHint)). CodexBar tries to auto-accept this, \
                but if it keeps appearing run: `cd "\(folderHint)" && claude` and choose “Yes, proceed”, then retry.
                """
            }
            return """
            Claude CLI is waiting for a folder trust prompt. CodexBar tries to auto-accept this, but if it keeps \
            appearing open `claude` once, choose “Yes, proceed”, then retry.
            """
        }
        if lower.contains("token_expired") || lower.contains("token has expired") {
            return "Claude CLI token expired. Run `claude login` to refresh."
        }
        if lower.contains("authentication_error") {
            return "Claude CLI authentication error. Run `claude login`."
        }
        if lower.contains("failed to load usage data") {
            return "Claude CLI could not load usage data. Open the CLI and retry `/usage`."
        }
        return nil
    }

    // Collect remaining percentages in the order they appear; used as a backup when labels move/rename.
    private static func allPercents(_ text: String) -> [Int] {
        let lines = text.components(separatedBy: .newlines)
        return lines.compactMap { self.percentFromLine($0, assumeRemainingWhenUnclear: true) }
    }

    private static func extractReset(labelSubstring: String, context: LabelSearchContext) -> String? {
        let lines = context.lines
        let label = self.normalizedForLabelSearch(labelSubstring)
        for (idx, normalizedLine) in context.normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = lines.dropFirst(idx).prefix(14)
            for candidate in window {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = self.normalizedForLabelSearch(trimmed)
                if normalized.hasPrefix("current "), !normalized.contains(label) { break }
                if let reset = self.resetFromLine(candidate) { return reset }
            }
        }
        return nil
    }

    private static func extractReset(labelSubstrings: [String], context: LabelSearchContext) -> String? {
        for label in labelSubstrings {
            if let value = self.extractReset(labelSubstring: label, context: context) { return value }
        }
        return nil
    }

    private static func resetFromLine(_ line: String) -> String? {
        guard let range = line.range(of: "Resets", options: [.caseInsensitive]) else { return nil }
        let raw = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return self.cleanResetLine(raw)
    }

    private static func normalizedForLabelSearch(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // Capture all "Resets ..." strings to surface in the menu.
    private static func allResets(_ text: String) -> [String] {
        let pat = #"Resets[^\r\n]*"#
        guard let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        regex.enumerateMatches(in: text, options: [], range: nsrange) { match, _, _ in
            guard let match,
                  let r = Range(match.range(at: 0), in: text) else { return }
            let raw = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(self.cleanResetLine(raw))
        }
        return results
    }

    private static func cleanResetLine(_ raw: String) -> String {
        // TTY capture sometimes appends a stray ")" at line ends; trim it to keep snapshots stable.
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        let openCount = cleaned.count(where: { $0 == "(" })
        let closeCount = cleaned.count(where: { $0 == ")" })
        if openCount > closeCount { cleaned.append(")") }
        return cleaned
    }

    /// Attempts to parse a Claude reset string into a Date, using the current year and handling optional timezones.
    public static func parseResetDate(from text: String?, now: Date = .init()) -> Date? {
        guard let normalized = self.normalizeResetInput(text) else { return nil }
        let (raw, timeZone) = normalized

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone ?? TimeZone.current
        formatter.defaultDate = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone

        if let date = self.parseDate(raw, formats: Self.resetDateTimeWithMinutes, formatter: formatter) {
            var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            comps.second = 0
            return calendar.date(from: comps)
        }
        if let date = self.parseDate(raw, formats: Self.resetDateTimeHourOnly, formatter: formatter) {
            var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            comps.minute = 0
            comps.second = 0
            return calendar.date(from: comps)
        }

        if let time = self.parseDate(raw, formats: Self.resetTimeWithMinutes, formatter: formatter) {
            let comps = calendar.dateComponents([.hour, .minute], from: time)
            guard let anchored = calendar.date(
                bySettingHour: comps.hour ?? 0,
                minute: comps.minute ?? 0,
                second: 0,
                of: now) else { return nil }
            if anchored >= now { return anchored }
            return calendar.date(byAdding: .day, value: 1, to: anchored)
        }

        guard let time = self.parseDate(raw, formats: Self.resetTimeHourOnly, formatter: formatter) else { return nil }
        let comps = calendar.dateComponents([.hour], from: time)
        guard let anchored = calendar.date(
            bySettingHour: comps.hour ?? 0,
            minute: 0,
            second: 0,
            of: now) else { return nil }
        if anchored >= now { return anchored }
        return calendar.date(byAdding: .day, value: 1, to: anchored)
    }

    private static let resetTimeWithMinutes = ["h:mma", "h:mm a", "HH:mm", "H:mm"]
    private static let resetTimeHourOnly = ["ha", "h a"]

    private static let resetDateTimeWithMinutes = [
        "MMM d, h:mma",
        "MMM d, h:mm a",
        "MMM d h:mma",
        "MMM d h:mm a",
        "MMM d, HH:mm",
        "MMM d HH:mm",
    ]

    private static let resetDateTimeHourOnly = [
        "MMM d, ha",
        "MMM d, h a",
        "MMM d ha",
        "MMM d h a",
    ]

    private static func normalizeResetInput(_ text: String?) -> (String, TimeZone?)? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(
            of: #"(?<=\d)\.(\d{2})\b"#,
            with: ":$1",
            options: .regularExpression)

        let timeZone = self.extractTimeZone(from: &raw)
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : (raw, timeZone)
    }

    private static func extractTimeZone(from text: inout String) -> TimeZone? {
        guard let tzRange = text.range(of: #"\(([^)]+)\)"#, options: .regularExpression) else { return nil }
        let tzID = String(text[tzRange]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        text.removeSubrange(tzRange)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeZone(identifier: tzID)
    }

    private static func parseDate(_ text: String, formats: [String], formatter: DateFormatter) -> Date? {
        for pattern in formats {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // Extract login/plan string from CLI output.
    private static func extractLoginMethod(text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let explicit = self.extractFirst(pattern: #"(?i)login\s+method:\s*(.+)"#, text: text) {
            return self.cleanPlan(explicit)
        }
        // Capture any "Claude <...>" phrase (e.g., Max/Pro/Ultra/Team) to avoid future plan-name churn.
        // Strip any leading ANSI that may have survived (rare) before matching.
        let planPattern = #"(?i)(claude\s+[a-z0-9][a-z0-9\s._-]{0,24})"#
        var candidates: [String] = []
        if let regex = try? NSRegularExpression(pattern: planPattern, options: []) {
            let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: nsrange) { match, _, _ in
                guard let match,
                      match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: text) else { return }
                let raw = String(text[r])
                let val = Self.cleanPlan(raw)
                candidates.append(val)
            }
        }
        if let plan = candidates.first(where: { cand in
            let lower = cand.lowercased()
            return !lower.contains("code v") && !lower.contains("code version") && !lower.contains("code")
        }) {
            return plan
        }
        return nil
    }

    /// Strips ANSI and stray bracketed codes like "[22m" that can survive CLI output.
    private static func cleanPlan(_ text: String) -> String {
        UsageFormatter.cleanPlanName(text)
    }

    private static func dumpIfNeeded(enabled: Bool, reason: String, usage: String, status: String?) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var parts = [
            "=== Claude parse dump @ \(stamp) ===",
            "Reason: \(reason)",
            "",
            "--- usage (clean) ---",
            usage,
            "",
        ]
        if let status {
            parts.append(contentsOf: [
                "--- status (raw/optional) ---",
                status,
                "",
            ])
        }
        let body = parts.joined(separator: "\n")
        Task { @MainActor in self.recordDump(body) }
    }

    // MARK: - Dump storage (in-memory ring buffer)

    @MainActor private static var recentDumps: [String] = []

    @MainActor private static func recordDump(_ text: String) {
        if self.recentDumps.count >= 5 { self.recentDumps.removeFirst() }
        self.recentDumps.append(text)
    }

    public static func latestDumps() async -> String {
        await MainActor.run {
            let result = Self.recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Claude parse dumps captured yet." : result
        }
    }

    private static func extractUsageErrorJSON(text: String) -> String? {
        let pattern = #"Failed to load usage data:\s*(\{.*\})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let jsonRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        let jsonString = String(text[jsonRange])
        let compactJSON = jsonString.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let data = (compactJSON.isEmpty ? jsonString : compactJSON).data(using: .utf8)
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any]
        else {
            return nil
        }

        let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = error["details"] as? [String: Any]
        let code = (details?["error_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if let message, !message.isEmpty { parts.append(message) }
        if let code, !code.isEmpty { parts.append("(\(code))") }

        guard !parts.isEmpty else { return nil }
        let hint = parts.joined(separator: " ")

        if let code, code.lowercased().contains("token") {
            return "\(hint). Run `claude login` to refresh."
        }
        return "Claude CLI error: \(hint)"
    }

    // MARK: - Process helpers

    static func probeWorkingDirectoryURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return fm.temporaryDirectory
        }
    }

    // Run claude CLI inside a PTY so we can respond to interactive permission prompts.
    private static func capture(subcommand: String, binary: String, timeout: TimeInterval) async throws -> String {
        let stopOnSubstrings = subcommand == "/usage"
            ? [
                "Current session",
                "Failed to load usage data",
                "failed to load usage data",
            ]
            : []
        let idleTimeout: TimeInterval? = subcommand == "/usage" ? nil : 3.0
        let sendEnterEvery: TimeInterval? = subcommand == "/usage" ? 0.8 : nil
        do {
            return try await ClaudeCLISession.shared.capture(
                subcommand: subcommand,
                binary: binary,
                timeout: timeout,
                idleTimeout: idleTimeout,
                stopOnSubstrings: stopOnSubstrings,
                settleAfterStop: subcommand == "/usage" ? 2.0 : 0.25,
                sendEnterEvery: sendEnterEvery)
        } catch ClaudeCLISession.SessionError.processExited {
            await ClaudeCLISession.shared.reset()
            throw ClaudeStatusProbeError.timedOut
        } catch ClaudeCLISession.SessionError.timedOut {
            throw ClaudeStatusProbeError.timedOut
        } catch ClaudeCLISession.SessionError.launchFailed(_) {
            throw ClaudeStatusProbeError.claudeNotInstalled
        } catch {
            await ClaudeCLISession.shared.reset()
            throw error
        }
    }
}
