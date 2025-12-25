import Foundation
#if canImport(os.log)
import os.log
#endif

public protocol ClaudeUsageFetching: Sendable {
    func loadLatestUsage(model: String) async throws -> ClaudeUsageSnapshot
    func debugRawProbe(model: String) async -> String
    func detectVersion() -> String?
}

public struct ClaudeUsageSnapshot: Sendable {
    public let primary: RateWindow
    public let secondary: RateWindow?
    public let opus: RateWindow?
    public let providerCost: ProviderCostSnapshot?
    public let updatedAt: Date
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let rawText: String?

    public init(
        primary: RateWindow,
        secondary: RateWindow?,
        opus: RateWindow?,
        providerCost: ProviderCostSnapshot? = nil,
        updatedAt: Date,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        rawText: String?)
    {
        self.primary = primary
        self.secondary = secondary
        self.opus = opus
        self.providerCost = providerCost
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
    private let preferWebAPI: Bool

    /// Creates a new ClaudeUsageFetcher.
    /// - Parameters:
    ///   - environment: Process environment (default: current process environment)
    ///   - preferWebAPI: If true, tries to fetch usage via claude.ai web API using browser cookies first.
    ///                   Falls back to CLI scraping if web API fails. (default: false)
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferWebAPI: Bool = false)
    {
        self.environment = environment
        self.preferWebAPI = preferWebAPI
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

        guard let session = makeWindow(firstWindowDict(["session_5h"])) else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }
        let weekAll = makeWindow(firstWindowDict(["week_all_models", "week_all"]))

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
            providerCost: nil,
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
        // Keep version detection consistent with the PTY probe which uses `TTYCommandRunner.which`.
        guard let path = TTYCommandRunner.which("claude") else { return nil }
        return Self.readString(cmd: path, args: ["--allowed-tools", "", "--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func debugRawProbe(model: String = "sonnet") async -> String {
        do {
            let snap = try await self.loadViaPTY(model: model, timeout: 10)
            let opus = snap.opus?.remainingPercent ?? -1
            let email = snap.accountEmail ?? "nil"
            let org = snap.accountOrganization ?? "nil"
            let weekly = snap.secondary?.remainingPercent ?? -1
            return """
            session_left=\(snap.primary.remainingPercent) weekly_left=\(weekly)
            opus_left=\(opus) email \(email) org \(org)
            \(snap)
            """
        } catch {
            return "Probe failed: \(error)"
        }
    }

    public func loadLatestUsage(model: String = "sonnet") async throws -> ClaudeUsageSnapshot {
        // Web API only when enabled (no CLI fallback in this mode).
        if self.preferWebAPI { return try await self.loadViaWebAPI() }

        // CLI scraping path (original behavior)
        do {
            return try await self.loadViaPTY(model: model, timeout: 10)
        } catch {
            return try await self.loadViaPTY(model: model, timeout: 24)
        }
    }

    // MARK: - Web API path (uses browser cookies)

    private func loadViaWebAPI() async throws -> ClaudeUsageSnapshot {
        let webData = try await ClaudeWebAPIFetcher.fetchUsage { msg in
            #if canImport(os.log)
            if #available(macOS 13.0, *) {
                os_log("%{public}@", log: .default, type: .debug, msg)
            }
            #endif
        }
        // Convert web API data to ClaudeUsageSnapshot format
        let primary = RateWindow(
            usedPercent: webData.sessionPercentUsed,
            windowMinutes: 5 * 60,
            resetsAt: webData.sessionResetsAt,
            resetDescription: webData.sessionResetsAt.map { Self.formatResetDate($0) })

        let secondary: RateWindow? = webData.weeklyPercentUsed.map { pct in
            RateWindow(
                usedPercent: pct,
                windowMinutes: 7 * 24 * 60,
                resetsAt: webData.weeklyResetsAt,
                resetDescription: webData.weeklyResetsAt.map { Self.formatResetDate($0) })
        }

        let opus: RateWindow? = webData.opusPercentUsed.map { opusPct in
            RateWindow(
                usedPercent: opusPct,
                windowMinutes: 7 * 24 * 60,
                resetsAt: webData.weeklyResetsAt,
                resetDescription: webData.weeklyResetsAt.map { Self.formatResetDate($0) })
        }

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: secondary,
            opus: opus,
            providerCost: webData.extraUsageCost,
            updatedAt: Date(),
            accountEmail: webData.accountEmail,
            accountOrganization: webData.accountOrganization,
            loginMethod: webData.loginMethod,
            rawText: nil)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
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
        let weekly = makeWindow(pctLeft: snap.weeklyPercentLeft, reset: snap.secondaryResetDescription)
        let opus = makeWindow(pctLeft: snap.opusPercentLeft, reset: snap.opusResetDescription)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: opus,
            providerCost: nil,
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
