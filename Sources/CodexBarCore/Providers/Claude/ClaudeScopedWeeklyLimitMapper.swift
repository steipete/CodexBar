import Foundation

/// Shared mapping for the model-scoped weekly limits returned by both Claude usage APIs.
enum ClaudeScopedWeeklyLimitMapper {
    struct Limit {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: Date?
        let modelID: String?
        let modelName: String?
    }

    static func extraRateWindows(
        from limits: [Limit]?,
        resetDescription: ((Date) -> String)? = nil) -> [NamedRateWindow]
    {
        guard let limits else { return [] }
        var seenIDs: Set<String> = []

        return limits.compactMap { limit in
            guard limit.group == "weekly", limit.kind == "weekly_scoped" else { return nil }
            guard let percent = limit.percent, percent.isFinite else { return nil }
            guard let modelName = self.nonEmpty(limit.modelName) else { return nil }
            guard !self.isAllModelsScope(modelID: limit.modelID, modelName: modelName) else { return nil }
            let identity = self.nonEmpty(limit.modelID) ?? modelName
            let slug = self.slug(identity)
            guard !slug.isEmpty else { return nil }

            let id = "claude-weekly-scoped-\(slug)"
            guard seenIDs.insert(id).inserted else { return nil }

            return NamedRateWindow(
                id: id,
                title: "\(modelName) only",
                window: RateWindow(
                    usedPercent: percent,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: limit.resetsAt,
                    resetDescription: limit.resetsAt.flatMap { resetDescription?($0) }))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return if let trimmed, !trimmed.isEmpty { trimmed } else { nil }
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isAllModelsScope(modelID: String?, modelName: String) -> Bool {
        if self.slug(modelName) == "all-models" {
            return true
        }
        guard let modelID = self.nonEmpty(modelID) else { return false }
        let idSlug = self.slug(modelID)
        return idSlug == "all-models" || idSlug.hasSuffix("-all-models")
    }
}
