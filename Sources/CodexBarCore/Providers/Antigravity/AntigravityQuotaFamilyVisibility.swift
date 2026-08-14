import Foundation

/// Antigravity reports every model family the plan covers, so an account that only runs Gemini still
/// receives a Claude/GPT pair pinned at 0%. Display surfaces hide a family once no lane in it reports
/// known usage above zero. Menu bar and icon selection rank by highest used, so an untouched family
/// never wins there and this stays a display-only filter.
public enum AntigravityQuotaFamilyVisibility {
    /// Window IDs that display surfaces should drop. Empty when every family is untouched, so a card
    /// or widget right after a reset still renders its lanes instead of an empty list.
    public static func idleWindowIDs(in snapshot: UsageSnapshot) -> Set<String> {
        let windows = (snapshot.extraRateWindows ?? [])
            .filter { AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id) }
        guard !windows.isEmpty else { return [] }
        let families = Dictionary(grouping: windows, by: Self.familyKey)
        let idleFamilies = families.filter { _, lanes in
            lanes.allSatisfy { !$0.usageKnown || $0.window.usedPercent <= 0 }
        }
        guard idleFamilies.count < families.count else { return [] }
        return Set(idleFamilies.values.flatMap { lanes in lanes.map(\.id) })
    }

    /// Classifies a lane the same way the widget row resolver does: the bucket ID carries the family and
    /// survives a display-text change, so it wins over the rendered title. A group with neither signal
    /// falls back to the title with its bucket suffix removed, which keeps an unfamiliar family's lanes
    /// on one key so a reset lane never hides while its active sibling stays.
    private static func familyKey(_ namedWindow: NamedRateWindow) -> String {
        // Provider-specific by design: these tokens are Antigravity's own quota families, not CodexBar providers.
        let id = namedWindow.id.lowercased()
        if id.contains("gemini") {
            return "gemini"
        }
        if id.contains("3p") || id.contains("third-party") {
            return "claude-gpt"
        }
        let title = namedWindow.title.lowercased()
        if title.contains("gemini") {
            return "gemini"
        }
        if title.contains("claude") || title.contains("gpt") {
            return "claude-gpt"
        }
        // Titles render as a group title plus a bucket title, so drop the bucket half to key per family.
        for suffix in Self.bucketTitleSuffixes where title.hasSuffix(suffix) {
            let stripped = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return title
    }

    private static let bucketTitleSuffixes = [" 5-hour", " weekly"]
}
