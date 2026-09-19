import Foundation

/// Shortens Bifrost's `per_model_usage[].model` identifiers for display in detail rows.
///
/// Bifrost's `provider/model` syntax (e.g. `bedrock/us.anthropic.claude-sonnet-5`) is only its request
/// routing format; usage tracking reports the upstream model ID unchanged. Routed through AWS Bedrock,
/// that ID is a cross-region inference profile: `<geo>.<vendor>.<name>-<version>:<revision>`
/// (`us.anthropic.claude-sonnet-5`, `amazon.nova-pro-v1:0`). The geo and vendor segments are routing
/// metadata with no display value once a row is already scoped to one provider.
///
/// This deliberately strips only a fixed allowlist of leading segments rather than splitting on `.` and
/// keeping the tail: dots also occur inside version numbers a gateway can legitimately route
/// (`gpt-4.1`, `claude-3.5-sonnet`, `gemini-1.5-pro`), and a positional split would corrupt those.
///
/// Mirrors the prefix rules in `CostUsagePricing.normalizeClaudeModel` (pricing-lookup normalization),
/// but stays a separate, display-only helper: coupling display output to pricing logic is how the two
/// would silently diverge. Kept Bifrost-local, like `BifrostResetDuration`, until a second provider
/// needs it.
enum BifrostModelName {
    /// Longest-match-first so `us-gov.` is not left mangled by a `us.` match.
    private static let geoPrefixes = ["us-gov.", "us.", "eu.", "apac.", "global."]

    /// Provider-specific by design: these are AWS Bedrock's own vendor-namespace segments inside a
    /// cross-region inference profile ID, not CodexBar app-provider routing logic.
    private static let vendorPrefixes = [
        "ai21.", "amazon.", "anthropic.", "cohere.", "deepseek.", "luma.", "meta.", "mistral.",
        "openai.", "qwen.", "stability.", "twelvelabs.", "writer.",
    ]

    private static let bedrockRevisionSuffix = #"-v\d+:\d+$"#

    static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        var cleaned = trimmed
        cleaned = self.stripPrefix(cleaned, from: self.geoPrefixes)
        cleaned = self.stripPrefix(cleaned, from: self.vendorPrefixes)
        if let range = cleaned.range(of: self.bedrockRevisionSuffix, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        cleaned = UsageFormatter.modelDisplayName(cleaned)

        return cleaned.isEmpty ? trimmed : cleaned
    }

    private static func stripPrefix(_ value: String, from prefixes: [String]) -> String {
        let lowered = value.lowercased()
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }
}
