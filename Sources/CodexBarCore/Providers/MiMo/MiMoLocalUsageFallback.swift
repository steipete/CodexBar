import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    public static func snapshot(now: Date = Date()) -> MiMoUsageSnapshot? {
        self.snapshot(cachePath: self.defaultCachePath(), now: now)
    }

    public static func snapshot(cachePath: String, now: Date) -> MiMoUsageSnapshot? {
        let url = URL(fileURLWithPath: cachePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let windows = json["windows"] as? [String: Any] ?? [:]
        let week = windows["week"] as? [String: Any] ?? [:]
        let today = windows["today"] as? [String: Any] ?? [:]
        let allTime = windows["all_time"] as? [String: Any] ?? [:]
        let sessionsScanned = json["sessions_scanned"] as? Int ?? 0

        let weekInput = Self.intValue(week["input"])
        let weekOutput = Self.intValue(week["output"])
        let weekCacheRead = Self.intValue(week["cache_read"])
        let weekTotal = weekInput + weekOutput + weekCacheRead

        let todayInput = Self.intValue(today["input"])
        let todayOutput = Self.intValue(today["output"])
        let todayCacheRead = Self.intValue(today["cache_read"])
        let todayTotal = todayInput + todayOutput + todayCacheRead

        let allInput = Self.intValue(allTime["input"])
        let allOutput = Self.intValue(allTime["output"])
        let allCacheRead = Self.intValue(allTime["cache_read"])
        let allTotal = allInput + allOutput + allCacheRead

        // planCode shows today/week/lifetime/sessions in the loginMethod row.
        var parts: [String] = []
        if todayTotal > 0 { parts.append("\(Self.fmtTokens(todayTotal)) today") }
        if weekTotal > 0 { parts.append("\(Self.fmtTokens(weekTotal)) week") }
        if allTotal > 0 { parts.append("\(Self.fmtTokens(allTotal)) total") }
        parts.append("\(sessionsScanned) sessions")
        let planCode = parts.joined(separator: " · ")

        // Progress bar: weekly usage vs lifetime baseline (this-week vs all-time activity ratio).
        // Idle (week=0) → bar empty, lifetime as baseline so the bar is meaningful once user resumes cc-mimo.
        let tokenLimit = max(allTotal, weekTotal + 1)
        let tokenUsed = weekTotal
        let tokenPercent = tokenLimit > 0 ? Double(tokenUsed) / Double(tokenLimit) : 0

        return MiMoUsageSnapshot(
            balance: 0,
            currency: "",
            planCode: planCode,
            planPeriodEnd: nil,
            planExpired: false,
            tokenUsed: tokenUsed,
            tokenLimit: tokenLimit,
            tokenPercent: tokenPercent,
            updatedAt: now)
    }

    private static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }
}
