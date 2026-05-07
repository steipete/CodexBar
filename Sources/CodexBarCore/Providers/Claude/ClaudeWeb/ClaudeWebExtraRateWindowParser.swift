import Foundation

enum ClaudeWebExtraRateWindowParser {
    private static let definitions: [(id: String, title: String, keys: [String])] = [
        (
            id: "claude-design",
            title: "Designs",
            keys: [
                "seven_day_design",
                "seven_day_claude_design",
                "claude_design",
                "design",
                "seven_day_omelette",
                "omelette",
                "omelette_promotional",
            ]),
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
        return (windows, sourceKeys)
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
