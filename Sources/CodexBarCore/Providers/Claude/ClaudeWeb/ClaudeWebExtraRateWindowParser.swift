import Foundation

enum ClaudeWebExtraRateWindowParser {
    private static let definitions: [(id: String, title: String, keys: [String])] = [
        (
            id: "claude-routines",
            title: "Daily Routines",
            keys: [
                "seven_day_routines",
                "seven_day_claude_routines",
                "claude_routines",
                "routines",
                "routine",
                "seven_day_cowork",
                "cowork",
            ]),
    ]

    static func parse(from json: [String: Any]) -> (windows: [NamedRateWindow], sourceKeys: [String: String]) {
        var windows: [NamedRateWindow] = []
        var sourceKeys: [String: String] = [:]
        windows.reserveCapacity(Self.definitions.count)

        for definition in Self.definitions {
            if let foundWindow = Self.firstUsageWindow(in: json, keys: definition.keys) {
                let rawWindow = foundWindow.window
                guard let utilization = Self.percentValue(from: rawWindow["utilization"]) else { continue }
                let resetsAt = (rawWindow["resets_at"] as? String).flatMap(Self.parseISO8601Date)
                windows.append(Self.namedWindow(
                    id: definition.id,
                    title: definition.title,
                    usedPercent: utilization,
                    resetsAt: resetsAt))
                sourceKeys[definition.id] = foundWindow.sourceKey
                continue
            }

            // Some accounts expose the key with null payloads (for example `seven_day_cowork: null`).
            // Preserve the bar in that case with a 0% window so the product section remains visible.
            if let key = Self.firstUsageKey(in: json, keys: definition.keys) {
                windows.append(Self.namedWindow(
                    id: definition.id,
                    title: definition.title,
                    usedPercent: 0,
                    resetsAt: nil))
                sourceKeys[definition.id] = key
            }
        }
        windows.append(contentsOf: Self.scopedWeeklyLimitWindows(from: json))
        return (windows, sourceKeys)
    }

    /// Surfaces any per-model weekly quota carve-out reported in the newer `limits` array —
    /// e.g. Anthropic's July 2026 promotional "up to 50% of your weekly limit on Fable 5"
    /// window, exposed as `kind: "weekly_scoped"` with `scope.model.display_name: "Fable"`.
    ///
    /// Deliberately generic: it surfaces *any* named scoped weekly limit rather than matching
    /// on "Fable" specifically, since these entries are promo-driven and Anthropic may reuse
    /// the same `weekly_scoped` shape for a different model once this promotion ends.
    private static func scopedWeeklyLimitWindows(from json: [String: Any]) -> [NamedRateWindow] {
        guard let limits = json["limits"] as? [[String: Any]] else { return [] }
        return limits.compactMap { entry -> NamedRateWindow? in
            guard entry["group"] as? String == "weekly", entry["kind"] as? String == "weekly_scoped" else {
                return nil
            }
            guard let percent = Self.percentValue(from: entry["percent"]) else { return nil }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let modelName = (model?["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let modelName, !modelName.isEmpty else { return nil }
            let resetsAt = (entry["resets_at"] as? String).flatMap(Self.parseISO8601Date)
            let slug = modelName.lowercased().replacingOccurrences(of: " ", with: "-")
            return Self.namedWindow(
                id: "claude-weekly-scoped-\(slug)",
                title: "\(modelName) only",
                usedPercent: percent,
                resetsAt: resetsAt)
        }
    }

    private static func namedWindow(
        id: String,
        title: String,
        usedPercent: Double,
        resetsAt: Date?) -> NamedRateWindow
    {
        NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetsAt,
                resetDescription: nil))
    }

    private static func firstUsageWindow(
        in json: [String: Any],
        keys: [String]) -> (window: [String: Any], sourceKey: String)?
    {
        for key in keys {
            if let window = json[key] as? [String: Any] {
                return (window, key)
            }
        }
        return nil
    }

    private static func firstUsageKey(in json: [String: Any], keys: [String]) -> String? {
        for key in keys where json.keys.contains(key) {
            return key
        }
        return nil
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
