import Foundation

public enum OpenCodexRouteTarget: Equatable, Sendable {
    case subscription(UsageProvider)
    case tokenOnly
    case unknown
}

public enum OpenCodexRouteDispatcher {
    public static func route(provider: String) -> OpenCodexRouteTarget {
        // Provider-specific by design: OpenCodex provider prefixes map onto subscription rows or token-only spend.
        switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai":
            .subscription(.codex)
        case "opencode-go":
            .subscription(.opencodego)
        case "kimi-coding", "kimi-for-coding":
            .subscription(.kimi)
        case "deepseek":
            .subscription(.deepseek)
        case "opencode-free", "opencode":
            .tokenOnly
        default:
            .unknown
        }
    }

    public static func route(modelName: String) -> OpenCodexRouteTarget {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else {
            return .subscription(.codex)
        }
        let prefix = String(trimmed[..<slash])
        guard !prefix.isEmpty else { return .unknown }
        return self.route(provider: prefix)
    }

    public static func countsTowardCodexSubscription(modelName: String) -> Bool {
        if case .subscription(.codex) = self.route(modelName: modelName) {
            return true
        }
        return false
    }

    public static func route(provider: String, modelName: String) -> OpenCodexRouteTarget {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.contains("/") {
            let modelRoute = self.route(modelName: trimmedModel)
            if modelRoute != .unknown {
                return modelRoute
            }
        }
        return self.route(provider: provider)
    }
}
