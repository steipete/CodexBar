import Foundation
import os.log

public protocol ClaudeUsageFetching: Sendable {
    func loadLatestUsage(model: String) async throws -> ClaudeUsageSnapshot
    func debugRawProbe(model: String) async -> String
    func detectVersion() -> String?
}

public struct ClaudeUsageSnapshot: Sendable {
    public let primary: RateWindow
    public let secondary: RateWindow
    public let opus: RateWindow?
    public let updatedAt: Date
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let rawText: String?

    public init(
        primary: RateWindow,
        secondary: RateWindow,
        opus: RateWindow?,
        updatedAt: Date,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        rawText: String?)
    {
        self.primary = primary
        self.secondary = secondary
        self.opus = opus
        self.updatedAt = updatedAt
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.rawText = rawText
    }
}

public enum ClaudeUsageError: LocalizedError, Sendable {
    case claudeNotInstalled
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .claudeNotInstalled:
            "Claude CLI is not installed. Install it from https://docs.claude.ai/claude-code."
        case let .parseFailed(details):
            "Could not parse Claude usage: \(details)"
        }
    }
}

public struct ClaudeUsageFetcher: ClaudeUsageFetching, Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    // MARK: - Parsing helpers

    public static func parse(json: Data) -> ClaudeUsageSnapshot? {
        guard let output = String(data: json, encoding: .utf8) else { return nil }
        return try? Self.parse(output: output)
    }

    private static func parse(output: String) throws -> ClaudeUsageSnapshot {
        guard
            let data = output.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeUsageError.parseFailed(output.prefix(500).description)
        }

        if let ok = obj["ok"] as? Bool, !ok {
            let hint = obj["hint"] as? String ?? (obj["pane_preview"] as? String ?? "")
            throw ClaudeUsageError.parseFailed(hint)
        }

        func firstWindowDict(_ keys: [String]) -> [String: Any]? {
            for key in keys {
                if let dict = obj[key] as? [String: Any] { return dict }
            }
            return nil
        }

        func makeWindow(_ dict: [String: Any]?) -> RateWindow? {
            guard let dict else { return nil }
            let pct = (dict["pct_used"] as? NSNumber)?.doubleValue ?? 0
            let resetText = dict["resets"] as? String
            return RateWindow(
                usedPercent: pct,
                windowMinutes: nil,
                resetsAt: Self.parseReset(text: resetText),
                resetDescription: resetText)
        }

        guard
            let session = makeWindow(firstWindowDict(["session_5h"])),
            let weekAll = makeWindow(firstWindowDict(["week_all_models", "week_all"]))
        else {
            throw ClaudeUsageError.parseFailed("missing session/weekly data")
        }

        let rawEmail = (obj["account_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (rawEmail?.isEmpty ?? true) ? nil : rawEmail
        let rawOrg = (obj["account_org"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = (rawOrg?.isEmpty ?? true) ? nil : rawOrg
        let loginMethod = (obj["login_method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let opusWindow: RateWindow? = {
            let candidates = firstWindowDict([
                "week_sonnet",
                "week_sonnet_only",
                "week_opus",
            ])
            guard let opus = candidates else { return nil }
            let pct = (opus["pct_used"] as? NSNumber)?.doubleValue ?? 0
            let resets = opus["resets"] as? String
            return RateWindow(
                usedPercent: pct,
                windowMinutes: nil,
                resetsAt: Self.parseReset(text: resets),
                resetDescription: resets)
        }()
        return ClaudeUsageSnapshot(
            primary: session,
            secondary: weekAll,
            opus: opusWindow,
            updatedAt: Date(),
            accountEmail: email,
            accountOrganization: org,
            loginMethod: loginMethod,
            rawText: output)
    }

    private static func parseReset(text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: "(")
        let timePart = parts.first?.trimmingCharacters(in: .whitespaces)
        let tzPart = parts.count > 1
            ? parts[1].replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
            : nil
        let tz = tzPart.flatMap(TimeZone.init(identifier:))
        let formats = ["ha", "h:mma", "MMM d 'at' ha", "MMM d 'at' h:mma"]
        for format in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = tz ?? TimeZone.current
            df.dateFormat = format
            if let t = timePart, let date = df.date(from: t) { return date }
        }
        return nil
    }

    // MARK: - Public API

    public func detectVersion() -> String? {
        guard let path = Self.which("claude") else { return nil }
        return Self.readString(cmd: path, args: ["--allowed-tools", "", "--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func debugRawProbe(model: String = "sonnet") async -> String {
        do {
            let snap = try await self.loadViaPTY(model: model, timeout: 10)
            let opus = snap.opus?.remainingPercent ?? -1
            let email = snap.accountEmail ?? "nil"
            let org = snap.accountOrganization ?? "nil"
            return """
            session_left=\(snap.primary.remainingPercent) weekly_left=\(snap.secondary.remainingPercent)
            opus_left=\(opus) email \(email) org \(org)
            \(snap)
            """
        } catch {
            return "Probe failed: \(error)"
        }
    }

    public func loadLatestUsage(model: String = "sonnet") async throws -> ClaudeUsageSnapshot {
        do {
            return try await self.loadViaPTY(model: model, timeout: 10)
        } catch {
            return try await self.loadViaPTY(model: model, timeout: 24)
        }
    }

    // MARK: - PTY-based probe (no tmux)

    private func loadViaPTY(model: String, timeout: TimeInterval = 10) async throws -> ClaudeUsageSnapshot {
        guard TTYCommandRunner.which("claude") != nil else { throw ClaudeUsageError.claudeNotInstalled }
        let probe = ClaudeStatusProbe(claudeBinary: "claude", timeout: timeout)
        let snap = try await probe.fetch()

        guard let sessionPctLeft = snap.sessionPercentLeft else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }

        func makeWindow(pctLeft: Int?, reset: String?) -> RateWindow? {
            guard let left = pctLeft else { return nil }
            let used = max(0, min(100, 100 - Double(left)))
            let resetClean = reset?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RateWindow(
                usedPercent: used,
                windowMinutes: nil,
                resetsAt: ClaudeStatusProbe.parseResetDate(from: resetClean),
                resetDescription: resetClean)
        }

        let primary = makeWindow(pctLeft: sessionPctLeft, reset: snap.primaryResetDescription)!
        let weekly = makeWindow(pctLeft: snap.weeklyPercentLeft, reset: snap.secondaryResetDescription)!
        let opus = makeWindow(pctLeft: snap.opusPercentLeft, reset: snap.opusResetDescription)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: opus,
            updatedAt: Date(),
            accountEmail: snap.accountEmail,
            accountOrganization: snap.accountOrganization,
            loginMethod: snap.loginMethod,
            rawText: snap.rawText)
    }

    // MARK: - Process helpers

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else { return nil }
        return path
    }

    private static func readString(cmd: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cmd)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
