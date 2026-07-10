import Foundation

/// Local coding-activity signal for the opt-in adaptive refresh replay harness.
///
/// Reports how many seconds ago the newest Codex / Claude Code session transcript was written, as a
/// privacy-safe proxy for "a coding turn just happened, so provider quota is being spent right now".
/// It reads only file *metadata* (modification/creation dates, size) — never file contents, project
/// paths, or account data.
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
/// Adding the size/creation-date fields below reuses the same `contentsOfDirectory` /
/// `resourceValues` calls the mtime-only walk already made (more resource keys per call, not more
/// calls), so it doesn't add directory traversals.
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
    /// How long the newest Codex transcript has been growing: its (mtime − creationDate), clamped
    /// to >= 0. A proxy for "how long has the current session been running" — not a separate age
    /// field, since age = `codexSecondsSinceActivity` + `codexSessionDurationSeconds`.
    let codexSessionDurationSeconds: TimeInterval?
    /// The Claude Code counterpart of `codexSessionDurationSeconds`.
    let claudeSessionDurationSeconds: TimeInterval?
    /// Size in bytes of the newest Codex transcript. Recorded as a stateless raw value — offline
    /// replay analysis computes deltas between consecutive decisions to estimate burn intensity;
    /// this probe never computes a delta itself.
    let codexTranscriptBytes: Int64?
    /// The Claude Code counterpart of `codexTranscriptBytes`.
    let claudeTranscriptBytes: Int64?
    /// Count of Codex `.jsonl` transcripts (within the bounded lookback window) modified in the
    /// last `activeTranscriptWindowSeconds`. Captures concurrent-session intensity — several agents
    /// running at once — that a newest-file-only metric misses.
    let codexActiveTranscriptCount: Int?
    /// The Claude Code counterpart of `codexActiveTranscriptCount`.
    let claudeActiveTranscriptCount: Int?
}

enum CodingActivityProbe {
    /// Codex writes a rollout transcript per session under `~/.codex/sessions/YYYY/MM/DD/`.
    private static let codexSessionsSubpath = ".codex/sessions"
    /// Claude Code appends a `.jsonl` transcript per session under `~/.claude/projects/<cwd>/`.
    private static let claudeProjectsSubpath = ".claude/projects"
    /// How many calendar days back (inclusive of today) the Codex walk looks: today and yesterday.
    private static let codexLookbackDays = 2
    /// A transcript modified more recently than this counts toward `*ActiveTranscriptCount`.
    private static let activeTranscriptWindowSeconds: TimeInterval = 300

    private static let statResourceKeys: [URLResourceKey] = [
        .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
    ]
    private static let statResourceKeySet: Set<URLResourceKey> = Set(Self.statResourceKeys)

    /// Per-file metadata read in a single `resourceValues` call — never the file's contents, path,
    /// or name beyond the `.jsonl` extension check already applied by the caller.
    private struct TranscriptStat: Sendable, Equatable {
        let modificationDate: Date
        let creationDate: Date?
        let fileSize: Int64?
    }

    /// The newest transcript's stat plus a count of how many transcripts (in the same bounded
    /// listing) were modified within `activeTranscriptWindowSeconds`. All per-file fields in
    /// `CodingActivitySample` for one CLI derive from `newest`, so they always describe the same
    /// file.
    private struct TranscriptAggregate {
        let newest: TranscriptStat
        let activeCount: Int
    }

    static func sample(
        now: Date = Date(),
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodingActivitySample
    {
        let codexRoot = homeDirectory.appendingPathComponent(self.codexSessionsSubpath, isDirectory: true)
        let claudeRoot = homeDirectory.appendingPathComponent(self.claudeProjectsSubpath, isDirectory: true)
        let codexAggregate = Self.aggregate(
            stats: Self.codexTranscriptStats(root: codexRoot, now: now, fileManager: fileManager), now: now)
        let claudeAggregate = Self.aggregate(
            stats: Self.claudeTranscriptStats(root: claudeRoot, fileManager: fileManager), now: now)
        return CodingActivitySample(
            codexSecondsSinceActivity: codexAggregate.map { Self.secondsSinceActivity($0, now: now) },
            claudeSecondsSinceActivity: claudeAggregate.map { Self.secondsSinceActivity($0, now: now) },
            codexSessionDurationSeconds: codexAggregate.flatMap(Self.sessionDurationSeconds),
            claudeSessionDurationSeconds: claudeAggregate.flatMap(Self.sessionDurationSeconds),
            codexTranscriptBytes: codexAggregate?.newest.fileSize,
            claudeTranscriptBytes: claudeAggregate?.newest.fileSize,
            codexActiveTranscriptCount: codexAggregate?.activeCount,
            claudeActiveTranscriptCount: claudeAggregate?.activeCount)
    }

    private static func secondsSinceActivity(_ aggregate: TranscriptAggregate, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(aggregate.newest.modificationDate))
    }

    private static func sessionDurationSeconds(_ aggregate: TranscriptAggregate) -> TimeInterval? {
        aggregate.newest.creationDate.map { max(0, aggregate.newest.modificationDate.timeIntervalSince($0)) }
    }

    /// Picks the newest-by-mtime stat and counts recently-modified entries. Returns nil when
    /// `stats` is empty (tree missing or no transcript in the bounded window), so every field
    /// derived from it is nil together.
    private static func aggregate(stats: [TranscriptStat], now: Date) -> TranscriptAggregate? {
        guard let newest = stats.max(by: { $0.modificationDate < $1.modificationDate }) else { return nil }
        let activeCount = stats.count { Self.isActive($0, now: now) }
        return TranscriptAggregate(newest: newest, activeCount: activeCount)
    }

    private static func isActive(_ stat: TranscriptStat, now: Date) -> Bool {
        now.timeIntervalSince(stat.modificationDate) < self.activeTranscriptWindowSeconds
    }

    /// Lists only today's and yesterday's `YYYY/MM/DD` directories (never the whole year/month
    /// tree) and returns stats for every `.jsonl` file found across them.
    private static func codexTranscriptStats(root: URL, now: Date, fileManager: FileManager) -> [TranscriptStat] {
        let calendar = Calendar(identifier: .gregorian)
        var stats: [TranscriptStat] = []
        for dayOffset in 0..<self.codexLookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let dayDirectory = root.appendingPathComponent(self.dayPathComponent(for: day, calendar: calendar))
            stats.append(contentsOf: Self.jsonlTranscriptStats(in: dayDirectory, fileManager: fileManager))
        }
        return stats
    }

    private static func dayPathComponent(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    /// Lists project directories non-recursively, then each project directory's direct `.jsonl`
    /// children non-recursively — never descending into a project's `memory/` or other
    /// subdirectories.
    private static func claudeTranscriptStats(root: URL, fileManager: FileManager) -> [TranscriptStat] {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }
        var stats: [TranscriptStat] = []
        for projectDirectory in projectDirectories {
            let isDirectory = (try? projectDirectory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDirectory else { continue }
            stats.append(contentsOf: Self.jsonlTranscriptStats(in: projectDirectory, fileManager: fileManager))
        }
        return stats
    }

    /// Non-recursive `.jsonl` stats directly inside `directory`. Missing directories (no sessions
    /// yet today, tool never installed) simply yield no stats.
    private static func jsonlTranscriptStats(in directory: URL, fileManager: FileManager) -> [TranscriptStat] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: statResourceKeys,
            options: [.skipsHiddenFiles])
        else {
            return []
        }
        return entries.compactMap { url -> TranscriptStat? in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Self.statResourceKeySet),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else {
                return nil
            }
            return TranscriptStat(
                modificationDate: modified,
                creationDate: values.creationDate,
                fileSize: values.fileSize.map(Int64.init))
        }
    }
}
