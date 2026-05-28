import Foundation

/// Maps Codex `additional_rate_limits` entries (model-specific limits such as GPT-5.3-Codex-Spark)
/// into named extra rate windows.
///
/// These limits are reported by the `wham/usage` API alongside, but separately from, the primary and
/// weekly Codex windows, so we surface them through `UsageSnapshot.extraRateWindows` rather than the core
/// primary/secondary lanes. When the field is absent the mapper returns an empty list and the snapshot is
/// unchanged.
enum CodexAdditionalRateLimitMapper {
    /// Stable id/title for the GPT-5.3-Codex-Spark limit so persistence and SwiftUI identity stay constant
    /// even if the API label wording shifts.
    static let sparkWindowID = "codex-spark"
    static let sparkWindowTitle = "Codex Spark"

    static func extraRateWindows(
        from additionalRateLimits: [CodexUsageResponse.AdditionalRateLimit]?,
        now: Date = Date()) -> [NamedRateWindow]
    {
        guard let additionalRateLimits, !additionalRateLimits.isEmpty else { return [] }
        var usedIDs = Set<String>()
        return additionalRateLimits.compactMap { entry in
            self.namedWindow(from: entry, usedIDs: &usedIDs, now: now)
        }
    }

    private static func namedWindow(
        from entry: CodexUsageResponse.AdditionalRateLimit,
        usedIDs: inout Set<String>,
        now: Date) -> NamedRateWindow?
    {
        // Model-specific limits report utilization in the primary window; fall back to the secondary
        // window only when a primary one is not present.
        guard let snapshot = entry.rateLimit?.primaryWindow ?? entry.rateLimit?.secondaryWindow else {
            return nil
        }
        guard let id = self.windowID(for: entry), usedIDs.insert(id).inserted else { return nil }
        let resetDate: Date? = snapshot.resetAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(snapshot.resetAt))
            : nil
        let window = RateWindow(
            usedPercent: Double(snapshot.usedPercent),
            windowMinutes: snapshot.limitWindowSeconds > 0 ? snapshot.limitWindowSeconds / 60 : nil,
            resetsAt: resetDate,
            resetDescription: resetDate.map { UsageFormatter.resetDescription(from: $0, now: now) })
        return NamedRateWindow(id: id, title: self.windowTitle(for: entry), window: window)
    }

    private static func windowID(for entry: CodexUsageResponse.AdditionalRateLimit) -> String? {
        if self.isSpark(entry) { return self.sparkWindowID }
        guard let source = self.firstNonEmpty(entry.meteredFeature, entry.limitName) else { return nil }
        let slug = self.slug(source)
        return slug.isEmpty ? nil : "codex-\(slug)"
    }

    private static func windowTitle(for entry: CodexUsageResponse.AdditionalRateLimit) -> String {
        if self.isSpark(entry) { return self.sparkWindowTitle }
        return self.firstNonEmpty(entry.limitName, entry.meteredFeature) ?? "Codex extra limit"
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
