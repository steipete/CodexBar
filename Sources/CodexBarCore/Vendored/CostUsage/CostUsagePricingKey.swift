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
        parserHash: String? = nil) -> String
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
            parts.append("modelsDevPricing:\n\(self.modelsDevPricingFingerprint(modelsDevArtifact.catalog))")
        } else {
            prefix = "builtin"
            parts.append("modelsDevPricing:none")
        }
        return "\(prefix)-\(self.sha256Hex(Data(parts.joined(separator: "\n").utf8)))"
    }

    private static func modelsDevPricingFingerprint(_ catalog: ModelsDevCatalog) -> String {
        var parts: [String] = []
        for providerID in catalog.providers.keys.sorted() {
            guard let provider = catalog.providers[providerID] else { continue }
            parts.append("provider=\(providerID)|\(provider.id ?? "")")
            for modelKey in provider.models.keys.sorted() {
                guard let model = provider.models[modelKey] else { continue }
                let cost = model.cost
                let contextOver200K = cost?.contextOver200K
                parts.append([
                    "model=\(modelKey)",
                    model.id,
                    self.optionalDoubleFingerprint(cost?.input),
                    self.optionalDoubleFingerprint(cost?.output),
                    self.optionalDoubleFingerprint(cost?.cacheRead),
                    self.optionalDoubleFingerprint(cost?.cacheWrite),
                    self.optionalDoubleFingerprint(contextOver200K?.input),
                    self.optionalDoubleFingerprint(contextOver200K?.output),
                    self.optionalDoubleFingerprint(contextOver200K?.cacheRead),
                    self.optionalDoubleFingerprint(contextOver200K?.cacheWrite),
                    model.limit?.context.map(String.init) ?? "nil",
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
