import Foundation

public enum OpenCodexRouteTarget: Equatable, Sendable {
    case subscription(UsageProvider)
    case tokenOnly
    case unknown
}

public enum OpenCodexRouteDispatcher {
    public static func route(
        provider: String,
        oauthBackedProviderIDs: Set<String> = []) -> OpenCodexRouteTarget
    {
        // Provider-specific by design: OpenCodex provider prefixes map onto subscription rows or token-only spend.
        let providerID = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch providerID {
        case "openai":
            return .subscription(.codex)
        case "xai":
            return oauthBackedProviderIDs.contains(providerID) ? .subscription(.grok) : .tokenOnly
        case "opencode-go":
            return .subscription(.opencodego)
        case "kimi-coding", "kimi-for-coding":
            return .subscription(.kimi)
        case "deepseek":
            return .subscription(.deepseek)
        case "opencode-free", "opencode":
            return .tokenOnly
        default:
            return .unknown
        }
    }

    public static func route(modelName: String, oauthBackedProviderIDs: Set<String> = []) -> OpenCodexRouteTarget {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else {
            return .subscription(.codex)
        }
        let prefix = String(trimmed[..<slash])
        guard !prefix.isEmpty else { return .unknown }
        return self.route(provider: prefix, oauthBackedProviderIDs: oauthBackedProviderIDs)
    }

    public static func countsTowardCodexSubscription(modelName: String) -> Bool {
        if case .subscription(.codex) = self.route(modelName: modelName) {
            return true
        }
        return false
    }

    public static func route(
        provider: String,
        modelName: String,
        oauthBackedProviderIDs: Set<String> = []) -> OpenCodexRouteTarget
    {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.contains("/") {
            let modelRoute = self.route(
                modelName: trimmedModel,
                oauthBackedProviderIDs: oauthBackedProviderIDs)
            if modelRoute != .unknown {
                return modelRoute
            }
        }
        return self.route(provider: provider, oauthBackedProviderIDs: oauthBackedProviderIDs)
    }
}
