#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

enum CostUsagePricingKey {
    static func codex(
        modelsDevArtifact: ModelsDevCacheArtifact?,
        formulaVersion: Int,
        parserHash: String? = nil,
        modelsDevProviderIDs: Set<String> = ["openai"]) -> String
    {
        var parts = [
            "costFormulaVersion=\(formulaVersion)",
            "builtInPricing:\n\(CostUsagePricing.codexBuiltInPricingFingerprint())",
        ]
        if let parserHash {
            parts.append("parserHash=\(parserHash)")
        }

        let prefix: String
        if let modelsDevArtifact {
            prefix = "models-dev-v\(modelsDevArtifact.version)"
            let modelsDevPricing = self.modelsDevPricingFingerprint(
                modelsDevArtifact.catalog,
                providerIDs: modelsDevProviderIDs)
            parts.append("modelsDevPricing:\n\(modelsDevPricing)")
        } else {
            prefix = "builtin"
            parts.append("modelsDevPricing:none")
        }
        return "\(prefix)-\(self.sha256Hex(Data(parts.joined(separator: "\n").utf8)))"
    }

    private static func modelsDevPricingFingerprint(
        _ catalog: ModelsDevCatalog,
        providerIDs: Set<String>) -> String
    {
        var parts: [String] = []
        let normalizedProviderIDs = Set(providerIDs.map(ModelsDevProvider.normalizeProviderID))
        for providerID in normalizedProviderIDs.sorted() {
            guard let provider = catalog.providers[providerID] else { continue }
            for modelKey in provider.models.keys.sorted() {
                guard let model = provider.models[modelKey], model.isPriceable else { continue }
                let cost = model.cost
                let contextOver200K = cost?.contextOver200K
                parts.append([
                    "provider=\(providerID)",
                    "model=\(modelKey)",
                    model.id,
                    self.optionalDoubleFingerprint(cost?.input),
                    self.optionalDoubleFingerprint(cost?.output),
                    self.optionalDoubleFingerprint(cost?.cacheRead),
                    self.optionalDoubleFingerprint(cost?.cacheWrite),
                    contextOver200K == nil ? "contextOver200K=absent" : "contextOver200K=present",
                    self.optionalDoubleFingerprint(contextOver200K?.input),
                    self.optionalDoubleFingerprint(contextOver200K?.output),
                    self.optionalDoubleFingerprint(contextOver200K?.cacheRead),
                    self.optionalDoubleFingerprint(contextOver200K?.cacheWrite),
                ].joined(separator: "|"))
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalDoubleFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
