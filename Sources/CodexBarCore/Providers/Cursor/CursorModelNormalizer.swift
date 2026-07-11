import Foundation

public enum CursorModelProvider: String, Codable, Equatable, Sendable {
    case anthropic
    case openai
    case google
    case cursor
    case unknown
}

public struct CursorNormalizedModel: Equatable, Sendable {
    public let rawName: String
    public let displayName: String
    public let provider: CursorModelProvider
    public let family: String?
    public let version: String?
    public let mode: String?
    public let effort: String?
    public let pricingKey: String?

    public init(
        rawName: String,
        displayName: String,
        provider: CursorModelProvider,
        family: String?,
        version: String?,
        mode: String?,
        effort: String?,
        pricingKey: String?)
    {
        self.rawName = rawName
        self.displayName = displayName
        self.provider = provider
        self.family = family
        self.version = version
        self.mode = mode
        self.effort = effort
        self.pricingKey = pricingKey
    }
}

public enum CursorModelNormalizer {
    private static let effortTokens: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]
    private static let knownAnthropicFamilies: Set<String> = ["haiku", "sonnet", "opus", "fable"]

    public static func normalize(_ raw: String) -> CursorNormalizedModel {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CursorNormalizedModel(
                rawName: raw,
                displayName: raw,
                provider: .unknown,
                family: nil,
                version: nil,
                mode: nil,
                effort: nil,
                pricingKey: nil)
        }

        let normalized = self.stripPrefix(from: trimmed.lowercased())
        let tokens = normalized.split(separator: "-").map(String.init)
        guard let head = tokens.first else {
            return CursorNormalizedModel(
                rawName: raw,
                displayName: raw,
                provider: .unknown,
                family: nil,
                version: nil,
                mode: nil,
                effort: nil,
                pricingKey: nil)
        }

        switch head {
        case "claude":
            return self.normalizeAnthropic(rawName: raw, tokens: tokens)
        case "haiku", "sonnet", "opus", "fable":
            return self.normalizeAnthropic(rawName: raw, tokens: ["claude"] + tokens)
        case "composer":
            return self.normalizeComposer(rawName: raw, tokens: tokens)
        case "gemini":
            return self.generic(rawName: raw, tokens: tokens, provider: .google)
        case "cursor", "auto":
            return self.generic(rawName: raw, tokens: tokens, provider: .cursor)
        default:
            if head.hasPrefix("gpt") || head == "o1" || head == "o3" || head == "o4" {
                return self.normalizeOpenAI(rawName: raw, tokens: tokens)
            }
            return self.generic(rawName: raw, tokens: tokens, provider: .unknown)
        }
    }

    private static func stripPrefix(from raw: String) -> String {
        ["openai/", "openai:", "anthropic/", "anthropic.", "google/"].reduce(raw) { value, prefix in
            value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        }
    }

    private static func normalizeOpenAI(rawName: String, tokens: [String]) -> CursorNormalizedModel {
        let stripped = self.stripEffortSuffix(from: tokens)
        let pricingTokens = stripped.tokens
        let display = self.openAIDisplayName(tokens: pricingTokens)
        let candidate = pricingTokens.joined(separator: "-")
        return CursorNormalizedModel(
            rawName: rawName,
            displayName: display,
            provider: .openai,
            family: pricingTokens.first,
            version: pricingTokens.dropFirst().first,
            mode: nil,
            effort: stripped.effort,
            pricingKey: CostUsagePricing.supportedCodexPricingKey(candidate))
    }

    private static func stripEffortSuffix(from tokens: [String]) -> (tokens: [String], effort: String?) {
        var stripped = tokens
        var effort: String?
        if stripped.suffix(2) == ["extra", "high"] {
            stripped.removeLast(2)
            effort = "extra-high"
        } else if let suffix = stripped.last, self.effortTokens.contains(suffix) {
            stripped.removeLast()
            effort = suffix
        }
        return (stripped, effort)
    }

    private static func openAIDisplayName(tokens: [String]) -> String {
        guard let first = tokens.first else { return "GPT" }
        if first.hasPrefix("gpt") {
            let base = first.replacingOccurrences(of: "gpt", with: "GPT", options: [.anchored])
            guard tokens.count > 1 else { return base }
            let suffix = tokens.dropFirst().map(\.capitalized).joined(separator: " ")
            return "\(base)-\(suffix)"
        }
        return tokens.map(\.capitalized).joined(separator: " ")
    }

    private static func normalizeAnthropic(rawName: String, tokens: [String]) -> CursorNormalizedModel {
        var remainder = Array(tokens.dropFirst())
        let mode = remainder.contains("thinking") ? "thinking" : nil
        remainder.removeAll { $0 == "thinking" }
        let effort = remainder.last.flatMap { self.effortTokens.contains($0) ? $0 : nil }
        if effort != nil { remainder.removeLast() }

        let family: String?
        let versionParts: [String]
        if let first = remainder.first, self.knownAnthropicFamilies.contains(first) {
            family = first
            versionParts = remainder.dropFirst().flatMap { $0.split(separator: ".").map(String.init) }
        } else {
            versionParts = remainder.flatMap { $0.split(separator: ".").map(String.init) }
            family = self.inferAnthropicFamily(versionParts: versionParts, effort: effort)
        }
        let version = versionParts.isEmpty ? nil : versionParts.joined(separator: ".")
        let display = if let family {
            if family == "claude" {
                version.map { "Claude \($0)" } ?? "Claude"
            } else {
                version.map { "\(family.capitalized) \($0)" } ?? family.capitalized
            }
        } else {
            rawName
        }
        let pricingKey: String? = if let family, !versionParts.isEmpty {
            CostUsagePricing.supportedClaudePricingKey(
                (["claude", family] + versionParts).joined(separator: "-"))
        } else {
            nil
        }

        return CursorNormalizedModel(
            rawName: rawName,
            displayName: display,
            provider: .anthropic,
            family: family,
            version: version,
            mode: mode,
            effort: effort,
            pricingKey: pricingKey)
    }

    private static func inferAnthropicFamily(versionParts: [String], effort: String?) -> String {
        if versionParts == ["4", "6"], effort == "max" || effort == "xhigh" { return "opus" }
        return "claude"
    }

    private static func normalizeComposer(rawName: String, tokens: [String]) -> CursorNormalizedModel {
        let mode = tokens.contains("standard") ? "standard" : "fast"
        let version = tokens.dropFirst().first { $0 != "fast" && $0 != "standard" }
        let pricingKey = version == "2.5" ? "composer-2.5-\(mode)" : nil
        return CursorNormalizedModel(
            rawName: rawName,
            displayName: version.map { "Composer \($0)" } ?? rawName,
            provider: .cursor,
            family: "composer",
            version: version,
            mode: mode,
            effort: nil,
            pricingKey: pricingKey)
    }

    private static func generic(
        rawName: String,
        tokens: [String],
        provider: CursorModelProvider) -> CursorNormalizedModel
    {
        CursorNormalizedModel(
            rawName: rawName,
            displayName: tokens.map(\.capitalized).joined(separator: " "),
            provider: provider,
            family: tokens.first,
            version: tokens.dropFirst().first,
            mode: nil,
            effort: nil,
            pricingKey: nil)
    }
}
