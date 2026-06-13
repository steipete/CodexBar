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

        var parts = ["Local"]
        if todayTotal > 0 { parts.append("\(Self.fmtTokens(todayTotal)) today") }
        if weekTotal > 0 { parts.append("\(Self.fmtTokens(weekTotal)) week") }
        if allTotal > 0 { parts.append("\(Self.fmtTokens(allTotal)) total") }
        parts.append("\(sessionsScanned) sessions")
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
            updatedAt: Self.updatedAt(json: json, url: url, fallback: now))
    }

    private static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private static func total(for window: [String: Any]) -> Int {
        ["input", "output", "cache_read", "cache_create"].reduce(into: 0) { total, key in
            let (sum, overflow) = total.addingReportingOverflow(Self.intValue(window[key]))
            total = overflow ? Int.max : sum
        }
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let i = raw as? Int { return max(0, i) }
        if let d = raw as? Double,
           d.isFinite,
           d >= 0,
           d <= Double(Int.max)
        {
            return Int(d)
        }
        if let s = raw as? String, let i = Int(s) { return max(0, i) }
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
