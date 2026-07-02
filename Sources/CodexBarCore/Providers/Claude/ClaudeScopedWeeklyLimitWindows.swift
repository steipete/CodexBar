import Foundation

/// Maps `limits[]` entries with `kind == "weekly_scoped"` from the Claude usage APIs into extra
/// rate windows (for example the "Fable" scoped weekly promo quota).
///
/// Both the claude.ai web usage API and the OAuth usage API return the `limits[]` array alongside
/// the legacy top-level window fields. Only scoped weekly entries are surfaced here; the legacy
/// fields stay authoritative for the session/weekly/model windows, so `session` and `weekly_all`
/// kinds are intentionally ignored to avoid duplicating those lanes.
enum ClaudeScopedWeeklyLimitWindows {
    struct Entry {
        let kind: String?
        let percent: Double?
        let resetsAt: Date?
        let modelDisplayName: String?
    }

    private static let scopedWeeklyKind = "weekly_scoped"
    private static let weeklyWindowMinutes = 7 * 24 * 60

    /// Builds extra rate windows from parsed `limits[]` entries.
    ///
    /// Entries are included whenever `percent` is present, regardless of `is_active`, so a scoped
    /// quota that has not been touched yet still renders as a visible 0%/n% bar.
    static func windows(
        from entries: [Entry],
        formatReset: ((Date) -> String)? = nil) -> [NamedRateWindow]
    {
        var windows: [NamedRateWindow] = []
        var usedIDs: Set<String> = []
        for entry in entries {
            guard entry.kind == Self.scopedWeeklyKind, let percent = entry.percent else { continue }
            let trimmedName = entry.modelDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
            let title = displayName.map { "\($0) weekly" } ?? "Scoped weekly"
            let baseID = "claude-scoped-\(Self.slug(displayName ?? "weekly"))"
            var id = baseID
            var suffix = 2
            while usedIDs.contains(id) {
                id = "\(baseID)-\(suffix)"
                suffix += 1
            }
            usedIDs.insert(id)
            windows.append(NamedRateWindow(
                id: id,
                title: title,
                window: RateWindow(
                    usedPercent: percent,
                    windowMinutes: Self.weeklyWindowMinutes,
                    resetsAt: entry.resetsAt,
                    resetDescription: entry.resetsAt.flatMap { formatReset?($0) })))
        }
        return windows
    }

    /// Parses the `JSONSerialization` form of `limits[]` used by the web usage path.
    static func entries(fromJSONValue value: Any?) -> [Entry] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.map { item in
            let scope = item["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            return Entry(
                kind: item["kind"] as? String,
                percent: Self.percentValue(from: item["percent"]),
                resetsAt: (item["resets_at"] as? String).flatMap(Self.parseISO8601Date),
                modelDisplayName: model?["display_name"] as? String)
        }
    }

    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        return String(mapped)
    }

    private static func percentValue(from value: Any?) -> Double? {
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        return nil
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
