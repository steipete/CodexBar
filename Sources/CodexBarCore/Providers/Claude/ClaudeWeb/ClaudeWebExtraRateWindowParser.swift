import CoreFoundation
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

        // Model-scoped weekly limits come first: they track the model budget users spend
        // day to day, while Daily Routines stays at 0% for accounts that never use
        // Routines/Cowork and would otherwise push the meaningful row down the card.
        windows.append(contentsOf: Self.scopedWeeklyLimitWindows(from: json))

        for definition in Self.definitions {
            guard let foundWindow = Self.firstUsageWindow(in: json, keys: definition.keys) else { continue }
            let rawWindow = foundWindow.window
            guard let utilization = Self.percentValue(from: rawWindow["utilization"]) else { continue }
            let resetsAt = ISO8601DateParser.parse(rawWindow["resets_at"] as? String)
            windows.append(Self.namedWindow(
                id: definition.id,
                title: definition.title,
                usedPercent: utilization,
                resetsAt: resetsAt))
            sourceKeys[definition.id] = foundWindow.sourceKey
        }
        return (windows, sourceKeys)
    }

    private static func scopedWeeklyLimitWindows(from json: [String: Any]) -> [NamedRateWindow] {
        ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: self.scopedWeeklyLimits(from: json))
    }

    /// Entry-by-entry parse of the `limits` array, shared with the OAuth path: a field of an
    /// unexpected type reads as missing instead of discarding the entry or its siblings.
    static func scopedWeeklyLimits(from json: [String: Any]) -> [ClaudeScopedWeeklyLimitMapper.Limit] {
        guard let limits = json["limits"] as? [Any] else { return [] }
        return limits.compactMap { $0 as? [String: Any] }.map { entry in
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            return ClaudeScopedWeeklyLimitMapper.Limit(
                kind: entry["kind"] as? String,
                group: entry["group"] as? String,
                percent: Self.percentValue(from: entry["percent"]),
                resetsAt: ISO8601DateParser.parse(entry["resets_at"] as? String),
                modelID: model?["id"] as? String,
                modelName: model?["display_name"] as? String)
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

    private static func percentValue(from value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }
}
