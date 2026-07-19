import Foundation

/// Local tracker fallback for MiMo when Xiaomi platform.xiaomimimo.com cookie is unavailable.
///
/// Reads the JSON cache produced by `Scripts/mimo-usage.py` which scans
/// `~/.claude-envs/mimo/.claude/projects/**/*.jsonl` and aggregates token usage
/// per time window. This is local accounting only — not real platform quota —
/// but gives users a useful view when SSO cookie access is blocked (keychain,
/// Chrome session-cookie expiry, etc.).
///
/// **Implicit opt-in**: this fallback only triggers when the cache file exists;
/// users who do not run `Scripts/mimo-usage.py` see no behavior change.
///
/// See `docs/mimo.md` "Local fallback (opt-in)" for setup instructions.
public enum MiMoLocalUsageFallback {
    public static func defaultCachePath() -> String {
        "\(NSHomeDirectory())/.codexbar/mimo-local-usage.json"
    }

    public static func cachePath(environment: [String: String]) -> String {
        guard let override = environment["MIMO_LOCAL_USAGE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        else {
            return self.defaultCachePath()
        }
        return NSString(string: override).expandingTildeInPath
    }

    public static func cacheExists(environment: [String: String]) -> Bool {
        FileManager.default.fileExists(atPath: self.cachePath(environment: environment))
    }

    public static func snapshot(now: Date = Date()) -> MiMoUsageSnapshot? {
        self.snapshot(cachePath: self.defaultCachePath(), now: now)
    }

    public static func snapshot(cachePath: String, now: Date = Date()) -> MiMoUsageSnapshot? {
        let url = URL(fileURLWithPath: cachePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let windows = json["windows"] as? [String: Any],
              let week = windows["week"] as? [String: Any],
              let today = windows["today"] as? [String: Any],
              let allTime = windows["all_time"] as? [String: Any]
        else {
            return nil
        }
        let sessionsScanned = Self.intValue(json["sessions_scanned"])
        let weekTotal = Self.total(for: week)
        let todayTotal = Self.total(for: today)
        let allTotal = Self.total(for: allTime)
        let updatedAt = Self.updatedAt(json: json, url: url, fallback: now)

        var parts = ["Local"]
        if todayTotal > 0 {
            parts.append("\(Self.fmtTokens(todayTotal)) today")
        }
        if weekTotal > 0 {
            parts.append("\(Self.fmtTokens(weekTotal)) week")
        }
        if allTotal > 0 {
            parts.append("\(Self.fmtTokens(allTotal)) total")
        }
        parts.append("\(sessionsScanned) sessions")
        // The cache is only as fresh as the last `Scripts/mimo-usage.py` run; flag a
        // frozen cache so the row is not misread as live accounting.
        if let stale = Self.staleSuffix(updatedAt: updatedAt, now: now) {
            parts.append(stale)
        }
        let planCode = parts.joined(separator: " · ")

        return MiMoUsageSnapshot(
            balance: 0,
            currency: "",
            planCode: planCode,
            planPeriodEnd: nil,
            planExpired: false,
            tokenUsed: 0,
            tokenLimit: 0,
            tokenPercent: 0,
            updatedAt: updatedAt)
    }

    private static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }

    /// Local usage is only as fresh as the last `Scripts/mimo-usage.py` run (typically a
    /// LaunchAgent). If the cache has not refreshed within this window its numbers are
    /// effectively frozen and should be labelled stale.
    static let staleThreshold: TimeInterval = 12 * 60 * 60

    /// Returns e.g. `stale 34d` when the cache is older than `staleThreshold`, else nil.
    private static func staleSuffix(updatedAt: Date, now: Date) -> String? {
        let age = now.timeIntervalSince(updatedAt)
        guard age > Self.staleThreshold else { return nil }
        return "stale \(Self.fmtAge(age))"
    }

    private static func fmtAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let day = 86400, hour = 3600
        if total >= day {
            return "\(total / day)d"
        }
        return "\(max(1, total / hour))h"
    }

    private static func total(for window: [String: Any]) -> Int {
        ["input", "output", "cache_read", "cache_create"].reduce(into: 0) { total, key in
            let (sum, overflow) = total.addingReportingOverflow(Self.intValue(window[key]))
            total = overflow ? Int.max : sum
        }
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let i = raw as? Int {
            return max(0, i)
        }
        if let d = raw as? Double,
           d.isFinite,
           d >= 0,
           d <= Double(Int.max)
        {
            return Int(d)
        }
        if let s = raw as? String, let i = Int(s) {
            return max(0, i)
        }
        return 0
    }

    private static func updatedAt(json: [String: Any], url: URL, fallback: Date) -> Date {
        if let raw = json["updated_at"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
                return parsed
            }
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? fallback
    }
}
