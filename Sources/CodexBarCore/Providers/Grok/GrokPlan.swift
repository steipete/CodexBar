import Foundation

/// Grok consumer plan labels. OIDC only tells CodexBar that the user signed in as SuperGrok;
/// the billed tier (SuperGrok vs SuperGrok Heavy) comes from CLI settings
/// `subscription_tier_display`.
public enum GrokPlan: Sendable {
    /// Prefer the billing `subscriptionTier`, then the OIDC login-method fallback.
    public static func loginMethod(subscriptionTier: String?, credentials: GrokCredentials?) -> String? {
        self.displayName(from: subscriptionTier) ?? credentials?.loginMethod
    }

    public static func displayName(from raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch self.compactToken(trimmed) {
        case "supergrokheavy", "heavy":
            return "SuperGrok Heavy"
        case "supergrok":
            return "SuperGrok"
        default:
            return trimmed
        }
    }

    private static func compactToken(_ raw: String) -> String {
        raw.lowercased().filter(\.isLetter)
    }
}
