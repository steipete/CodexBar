import Foundation

struct ModelsDevPricingTarget: Hashable, Sendable {
    let providerID: String
    let modelID: String
}

enum ModelsDevPricingTargetResolver {
    static func targets(providerID rawProviderID: String, modelID rawModelID: String) -> [ModelsDevPricingTarget] {
        let providerID = self.normalizedProviderID(rawProviderID)
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, self.isValidModelID(modelID) else { return [] }

        let resolvedModelID = self.modelID(modelID, for: providerID)
        guard self.isValidModelID(resolvedModelID) else { return [] }

        var providerIDs = [providerID]
        switch providerID {
        case "kimi-coding":
            providerIDs.append("kimi-for-coding")
        case "opencode-free":
            providerIDs.append("opencode")
        default:
            break
        }
        return providerIDs.map { ModelsDevPricingTarget(providerID: $0, modelID: resolvedModelID) }
    }

    private static func normalizedProviderID(_ rawProviderID: String) -> String {
        switch ModelsDevProvider.normalizeProviderID(rawProviderID) {
        case "x-ai":
            "xai"
        default:
            ModelsDevProvider.normalizeProviderID(rawProviderID)
        }
    }

    private static func modelID(_ modelID: String, for providerID: String) -> String {
        guard let slash = modelID.firstIndex(of: "/") else { return modelID }
        let prefix = String(modelID[..<slash])
        let remainder = String(modelID[modelID.index(after: slash)...])
        guard !remainder.isEmpty else { return modelID }

        if providerID == "openrouter" {
            return self.normalizedProviderID(prefix) == "openrouter" ? remainder : modelID
        }

        return self.normalizedProviderID(prefix) == providerID ? remainder : modelID
    }

    private static func isValidModelID(_ modelID: String) -> Bool {
        !modelID.isEmpty && !modelID.hasPrefix("/") && !modelID.hasSuffix("/")
    }
}
