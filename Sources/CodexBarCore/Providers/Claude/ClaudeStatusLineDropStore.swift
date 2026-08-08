import Foundation

/// Reads observations forwarded by a user-configured Claude statusLine command.
///
/// Selection is pure and separated from the filesystem so the freshness and profile rules can be tested
/// without touching disk, the network, or the Keychain.
public enum ClaudeStatusLineDropStore {
    /// A live session posts on every turn. Past this age the feed is treated as silent so the polled sources
    /// own the card again — a stale live value must never outrank a fresh poll.
    public static let freshnessWindow: TimeInterval = 15 * 60

    /// Tolerance for a shim clock running ahead of the app's. Beyond this an observation is rejected rather
    /// than trusted: an unbounded future timestamp would stay "fresh" forever and defeat the staleness bound
    /// just as surely as an absent one.
    public static let maximumClockSkew: TimeInterval = 5 * 60

    public static let directoryName = "claude-statusline"

    public static func directoryURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent(self.directoryName, isDirectory: true)
    }

    /// Picks the newest observation belonging to `expectedConfigDir`.
    ///
    /// Profile matching is not optional: the payload carries no account identity, so `CLAUDE_CONFIG_DIR` is the
    /// only evidence tying an observation to an account, and accepting a mismatch would render one account's
    /// numbers under another's card. A nil `expectedConfigDir` is the ambient default profile, which matches
    /// only observations that also reported no explicit config dir.
    public static func select(
        candidates: [ClaudeStatusLineRateLimits],
        expectedConfigDir: String?,
        now: Date = Date()) -> ClaudeStatusLineRateLimits?
    {
        candidates
            .filter { self.isFresh($0, now: now) && self.matchesProfile($0, expectedConfigDir: expectedConfigDir) }
            .max { $0.capturedAt < $1.capturedAt }
    }

    /// Modest clock skew between the shim and the app must not blank the feed, but an arbitrarily future
    /// timestamp is not evidence of freshness — it is an observation we cannot age.
    public static func isFresh(_ candidate: ClaudeStatusLineRateLimits, now: Date) -> Bool {
        let age = now.timeIntervalSince(candidate.capturedAt)
        return age <= self.freshnessWindow && age >= -self.maximumClockSkew
    }

    public static func matchesProfile(
        _ candidate: ClaudeStatusLineRateLimits,
        expectedConfigDir: String?) -> Bool
    {
        self.normalizedPath(candidate.configDir) == self.normalizedPath(expectedConfigDir)
    }

    /// Reads and parses every drop file. Unreadable or drifted files are skipped, never surfaced as errors.
    public static func loadCandidates(directory: URL, now: Date = Date()) -> [ClaudeStatusLineRateLimits] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return ClaudeStatusLinePayloadParser.parse(data, now: now)
        }
    }

    // MARK: - Snapshot mapping

    /// Maps an observation onto a usage snapshot.
    ///
    /// Deliberately partial: this feed carries no identity, plan, model-scoped weekly, Daily Routines or extra
    /// usage. Those rows come from the polled sources, so the caller must merge rather than replace.
    public static func makeSnapshot(from limits: ClaudeStatusLineRateLimits) -> ClaudeUsageSnapshot? {
        let fiveHour = limits.fiveHour.map { self.window($0, minutes: 300) }
        let sevenDay = limits.sevenDay.map { self.window($0, minutes: 10080) }
        // Mirrors the OAuth mapping: the weekly window is promoted when no five-hour window is present.
        guard let primary = fiveHour ?? sevenDay else { return nil }

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: fiveHour == nil ? nil : sevenDay,
            opus: nil,
            updatedAt: limits.capturedAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil)
    }

    private static func window(_ source: ClaudeStatusLineWindow, minutes: Int) -> RateWindow {
        RateWindow(
            usedPercent: source.usedPercent,
            windowMinutes: minutes,
            resetsAt: source.resetsAt,
            resetDescription: nil)
    }

    private static func normalizedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }
}
