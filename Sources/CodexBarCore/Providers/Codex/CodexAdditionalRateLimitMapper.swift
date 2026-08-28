import Foundation

/// Maps Codex `additional_rate_limits` entries (model-specific limits such as GPT-5.3-Codex-Spark)
/// into named extra rate windows.
///
/// These limits are reported by the `wham/usage` API alongside, but separately from, the primary and
/// weekly Codex windows, so we surface them through `UsageSnapshot.extraRateWindows` rather than the core
/// primary/secondary lanes. When the field is absent the mapper returns an empty list and the snapshot is
/// unchanged.
package enum CodexAdditionalRateLimitMapper {
    /// Stable ids/titles for GPT-5.3-Codex-Spark limits so SwiftUI identity stays constant even if the API
    /// label wording shifts. Keep the original 5-hour id for compatibility with the first Spark implementation.
    package static let sparkWindowID = "codex-spark"
    package static let sparkWeeklyWindowID = "codex-spark-weekly"
    static let sparkWindowTitle = "Codex Spark 5-hour"
    static let sparkWeeklyWindowTitle = "Codex Spark Weekly"

    static func extraRateWindows(
        from additionalRateLimits: [CodexUsageResponse.AdditionalRateLimit]?,
        now: Date = Date()) -> [NamedRateWindow]
    {
        guard let additionalRateLimits, !additionalRateLimits.isEmpty else { return [] }
        var usedIDs = Set<String>()
        return additionalRateLimits.flatMap { entry in
            self.namedWindows(from: entry, usedIDs: &usedIDs, now: now)
        }
    }

    private static func namedWindows(
        from entry: CodexUsageResponse.AdditionalRateLimit,
        usedIDs: inout Set<String>,
        now: Date) -> [NamedRateWindow]
    {
        if self.isSpark(entry) {
            return self.sparkWindows(from: entry, usedIDs: &usedIDs, now: now)
        }

        // Model-specific limits report utilization in the primary window; fall back to the secondary
        // window only when a primary one is not present.
        guard let snapshot = entry.rateLimit?.primaryWindow ?? entry.rateLimit?.secondaryWindow else {
            return []
        }
        guard let id = self.windowID(for: entry), usedIDs.insert(id).inserted else { return [] }
        return [self.namedWindow(
            id: id,
            title: self.windowTitle(for: entry),
            snapshot: snapshot,
            now: now)]
    }

    private static func sparkWindows(
        from entry: CodexUsageResponse.AdditionalRateLimit,
        usedIDs: inout Set<String>,
        now: Date) -> [NamedRateWindow]
    {
        let candidates: [(CodexUsageResponse.WindowSnapshot?, SparkWindowKind)] = [
            (entry.rateLimit?.primaryWindow, .fiveHour),
            (entry.rateLimit?.secondaryWindow, .weekly),
        ]

        return candidates.compactMap { snapshot, fallbackKind in
            guard let snapshot else { return nil }
            let kind = self.sparkWindowKind(for: snapshot, fallback: fallbackKind)
            guard usedIDs.insert(kind.id).inserted else { return nil }
            return self.namedWindow(id: kind.id, title: kind.title, snapshot: snapshot, now: now)
        }
    }

    private static func namedWindow(
        id: String,
        title: String,
        snapshot: CodexUsageResponse.WindowSnapshot,
        now: Date) -> NamedRateWindow
    {
        let resetDate: Date? = snapshot.resetAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(snapshot.resetAt))
            : nil
        let window = RateWindow(
            usedPercent: Double(snapshot.usedPercent),
            windowMinutes: snapshot.limitWindowSeconds > 0 ? snapshot.limitWindowSeconds / 60 : nil,
            resetsAt: resetDate,
            resetDescription: resetDate.map { UsageFormatter.resetDescription(from: $0, now: now) })
        return NamedRateWindow(id: id, title: title, window: window)
    }

    private enum SparkWindowKind {
        case fiveHour
        case weekly

        var id: String {
            switch self {
            case .fiveHour: CodexAdditionalRateLimitMapper.sparkWindowID
            case .weekly: CodexAdditionalRateLimitMapper.sparkWeeklyWindowID
            }
        }

        var title: String {
            switch self {
            case .fiveHour: CodexAdditionalRateLimitMapper.sparkWindowTitle
            case .weekly: CodexAdditionalRateLimitMapper.sparkWeeklyWindowTitle
            }
        }
    }

    private static func sparkWindowKind(
        for snapshot: CodexUsageResponse.WindowSnapshot,
        fallback: SparkWindowKind) -> SparkWindowKind
    {
        let minutes = snapshot.limitWindowSeconds > 0 ? snapshot.limitWindowSeconds / 60 : 0
        if minutes > 0, minutes <= 6 * 60 { return .fiveHour }
        if minutes >= 6 * 24 * 60 { return .weekly }
        return fallback
    }

    private static func windowID(for entry: CodexUsageResponse.AdditionalRateLimit) -> String? {
        guard let source = self.firstNonEmpty(entry.meteredFeature, entry.limitName) else { return nil }
        let slug = self.slug(source)
        return slug.isEmpty ? nil : "codex-\(slug)"
    }

    private static func windowTitle(for entry: CodexUsageResponse.AdditionalRateLimit) -> String {
        self.firstNonEmpty(entry.limitName, entry.meteredFeature) ?? "Codex extra limit"
    }

    private static func isSpark(_ entry: CodexUsageResponse.AdditionalRateLimit) -> Bool {
        [entry.limitName, entry.meteredFeature]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return nil
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
}
