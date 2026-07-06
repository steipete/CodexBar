import Foundation

/// Fork-only local coding-activity signal for the adaptive refresh replay harness (never upstreamed).
///
/// Reports how many seconds ago the newest Codex / Claude Code session transcript was written, as a
/// privacy-safe proxy for "a coding turn just happened, so provider quota is being spent right now".
/// It reads only file *modification times* — never file contents, project paths, or account data —
/// so the only thing it can contribute to a trace is two elapsed-seconds numbers.
///
/// Signal choice: transcript mtime tracks actual turns. Raw process presence is a weaker signal — an
/// editor or an unattended agent can sit open and idle for hours without spending anything. The probe
/// runs at adaptive-timer cadence (minutes apart) and only while tracing is enabled, so a bounded
/// directory walk is cheap.
///
/// Performance: an unbounded recursive walk of both trees measured ~15-23ms against this machine's
/// real home directory (~1600 files under `.codex/sessions` going back years, ~450 under
/// `.claude/projects`), well over the ~10ms budget for something sampled on every adaptive-timer
/// tick. Both walks below are bounded to keep the common case a handful of `stat` calls:
/// - Codex sessions are bucketed by day (`YYYY/MM/DD/rollout-*.jsonl`), so only today's and
///   yesterday's day directories are listed — never the full year/month tree.
/// - Claude transcripts sit directly under `.claude/projects/<project>/*.jsonl` with no further
///   nesting relevant here (some projects also hold a `memory/` subdirectory), so project
///   directories are listed non-recursively and only their direct `.jsonl` children are considered.
///
/// Trade-off: if neither Codex nor Claude wrote a transcript in the last two calendar days, the
/// probe reports "unavailable" (nil) even if an older transcript exists. That's acceptable for
/// shadow-mode telemetry whose only use is "was this decision made during an active coding
/// session" — it is never fed back into `AdaptiveRefreshPolicy`.
struct CodingActivitySample: Sendable, Equatable {
    /// Seconds since the newest Codex session file was modified, or nil when none is found within
    /// the bounded lookback window (today + yesterday).
    let codexSecondsSinceActivity: TimeInterval?
    /// Seconds since the newest Claude Code transcript was modified, or nil when none is found.
    let claudeSecondsSinceActivity: TimeInterval?
}

enum CodingActivityProbe {
    /// Codex writes a rollout transcript per session under `~/.codex/sessions/YYYY/MM/DD/`.
    private static let codexSessionsSubpath = ".codex/sessions"
    /// Claude Code appends a `.jsonl` transcript per session under `~/.claude/projects/<cwd>/`.
    private static let claudeProjectsSubpath = ".claude/projects"
    /// How many calendar days back (inclusive of today) the Codex walk looks: today and yesterday.
    private static let codexLookbackDays = 2

    private static let statResourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    private static let statResourceKeySet: Set<URLResourceKey> = Set(Self.statResourceKeys)

    static func sample(
        now: Date = Date(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodingActivitySample
    {
        let codexRoot = homeDirectory.appendingPathComponent(self.codexSessionsSubpath, isDirectory: true)
        let claudeRoot = homeDirectory.appendingPathComponent(self.claudeProjectsSubpath, isDirectory: true)
        let codexNewest = Self.newestCodexTranscriptModificationDate(
            root: codexRoot, now: now, fileManager: fileManager)
        let claudeNewest = Self.newestClaudeTranscriptModificationDate(root: claudeRoot, fileManager: fileManager)
        return CodingActivitySample(
            codexSecondsSinceActivity: codexNewest.map { max(0, now.timeIntervalSince($0)) },
            claudeSecondsSinceActivity: claudeNewest.map { max(0, now.timeIntervalSince($0)) })
    }

    /// Lists only today's and yesterday's `YYYY/MM/DD` directories (never the whole year/month
    /// tree) and returns the newest `.jsonl` modification date across them.
    private static func newestCodexTranscriptModificationDate(
        root: URL,
        now: Date,
        fileManager: FileManager) -> Date?
    {
        let calendar = Calendar(identifier: .gregorian)
        var newest: Date?
        for dayOffset in 0..<self.codexLookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let dayDirectory = root.appendingPathComponent(self.dayPathComponent(for: day, calendar: calendar))
            for candidate in Self.jsonlModificationDates(in: dayDirectory, fileManager: fileManager) {
                if newest == nil || candidate > newest! { newest = candidate }
            }
        }
        return newest
    }

    private static func dayPathComponent(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    /// Lists project directories non-recursively, then each project directory's direct `.jsonl`
    /// children non-recursively — never descending into a project's `memory/` or other
    /// subdirectories.
    private static func newestClaudeTranscriptModificationDate(root: URL, fileManager: FileManager) -> Date? {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }
        var newest: Date?
        for projectDirectory in projectDirectories {
            let isDirectory = (try? projectDirectory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDirectory else { continue }
            for candidate in Self.jsonlModificationDates(in: projectDirectory, fileManager: fileManager) {
                if newest == nil || candidate > newest! { newest = candidate }
            }
        }
        return newest
    }

    /// Non-recursive `.jsonl` modification dates directly inside `directory`. Missing directories
    /// (no sessions yet today, tool never installed) simply yield no dates.
    private static func jsonlModificationDates(in directory: URL, fileManager: FileManager) -> [Date] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Self.statResourceKeys,
            options: [.skipsHiddenFiles])
        else {
            return []
        }
        return entries.compactMap { url -> Date? in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Self.statResourceKeySet),
                  values.isRegularFile == true
            else {
                return nil
            }
            return values.contentModificationDate
        }
    }
}
