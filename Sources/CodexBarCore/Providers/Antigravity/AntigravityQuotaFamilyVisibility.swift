import Foundation

/// Display-only filtering for unused Antigravity quota families. Returned Claude/GPT allowances stay
/// visible even at zero usage because they describe available shared capacity.
public enum AntigravityQuotaFamilyVisibility {
    public enum KnownFamily: String, CaseIterable {
        case gemini
        case claudeGPT = "claude-gpt"
    }

    /// Stable bucket IDs take precedence over display titles on every surface.
    /// Provider-specific by design: these tokens classify Antigravity quota families, not provider routing.
    public static func knownFamily(windowID: String, title: String) -> KnownFamily? {
        guard AntigravityStatusSnapshot.isQuotaSummaryWindowID(windowID) else { return nil }
        let id = windowID.lowercased()
        if id.contains("gemini") { return .gemini }
        if id.contains("3p") || id.contains("third-party") { return .claudeGPT }
        let title = title.lowercased()
        if title.contains("gemini") { return .gemini }
        if title.contains("claude") || title.contains("gpt") { return .claudeGPT }
        return nil
    }

    /// Window IDs that display surfaces should drop. Empty when every family is untouched, so a card
    /// or widget right after a reset still renders its lanes instead of an empty list.
    public static func idleWindowIDs(in snapshot: UsageSnapshot) -> Set<String> {
        let windows = (snapshot.extraRateWindows ?? [])
            .filter { AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id) }
        guard !windows.isEmpty else { return [] }
        let families = Dictionary(grouping: windows, by: Self.familyKey)
        let idleFamilies = families.filter { _, lanes in
            lanes.allSatisfy { $0.usageKnown && $0.window.usedPercent <= 0 }
        }
        guard idleFamilies.count < families.count else { return [] }
        let hiddenFamilies = idleFamilies.filter { $0.key != KnownFamily.claudeGPT.rawValue }
        return Set(hiddenFamilies.values.flatMap { lanes in lanes.map(\.id) })
    }

    /// Classifies a lane the same way the widget row resolver does: the bucket ID carries the family and
    /// survives a display-text change, so it wins over the rendered title. A group with neither signal
    /// falls back to the title with its bucket suffix removed, which keeps an unfamiliar family's lanes
    /// on one key so a reset lane never hides while its active sibling stays.
    private static func familyKey(_ namedWindow: NamedRateWindow) -> String {
        if let family = self.knownFamily(windowID: namedWindow.id, title: namedWindow.title) {
            return family.rawValue
        }
        // Titles render as a group title plus a bucket title, so drop the bucket half to key per family.
        let title = namedWindow.title.lowercased()
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
