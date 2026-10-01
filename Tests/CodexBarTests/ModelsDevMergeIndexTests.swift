import Foundation
import Testing
@testable import CodexBarCore

struct ModelsDevMergeIndexTests {
    @Test
    func `indexed merge equals legacy merge with aliases snapshots and key collisions`() {
        let (fresh, cached) = Self.catalogs()
        let merged = fresh.mergingFallbackPricing(from: cached)
        #expect(merged == Self.legacyMerge(fresh, cached))
        #expect(merged.providers["removed"] == cached.providers["removed"])
        #expect(merged.providers["openai"]?.models.keys.contains {
            $0.hasPrefix("codexbar-fallback:")
        } == true)
        #expect(merged.mergingFallbackPricing(from: cached) == Self.legacyMerge(merged, cached))
    }

    @Test(arguments: [64, 128])
    func `stable identity computations grow linearly with distinct raw IDs`(count: Int) {
        let freshModels = Dictionary(uniqueKeysWithValues: (0..<count).map {
            ("fresh-\($0)", Self.model("fresh-\($0)"))
        })
        let cachedModels = Dictionary(uniqueKeysWithValues: (0..<count).map {
            ("cached-\($0)", Self.model("cached-\($0)"))
        })
        let fresh = ModelsDevCatalog(providers: ["openai": Self.provider(freshModels)])
        let cached = ModelsDevCatalog(providers: ["openai": Self.provider(cachedModels)])
        var oldCalls = 0
        let expected = Self.legacyMerge(fresh, cached) {
            oldCalls += 1
            return ModelsDevModelIDNormalizer.stableIdentity($0)
        }
        var newCalls = 0
        let actual = fresh.mergingFallbackPricing(from: cached) {
            newCalls += 1
            return ModelsDevModelIDNormalizer.stableIdentity($0)
        }
        #expect(actual == expected)
        #expect(newCalls == 2 * count)
        #expect(oldCalls == count + count * count + count * (count - 1) / 2)
    }

    @Test
    func `merge memo computes each raw identity once across duplicate entries`() {
        let (fresh, cached) = Self.catalogs()
        var calls: [String: Int] = [:]
        let merged = fresh.mergingFallbackPricing(from: cached) {
            calls[$0, default: 0] += 1
            return ModelsDevModelIDNormalizer.stableIdentity($0)
        }
        #expect(merged == Self.legacyMerge(fresh, cached))
        #expect(!calls.isEmpty)
        #expect(calls.values.allSatisfy { $0 == 1 })
    }

    @Test
    func `fallback replacement removes only the replaced priced identity`() throws {
        // Dictionary iteration chooses which fallback arrives first; exercise both identity relationships.
        for duplicate in [false, true] {
            for index in 0..<32 {
                let cachedModels = ["slot": Self.model("inserted-\(index)"), "later": Self.model("displaced")]
                let first = try #require(cachedModels.first)
                let other = try #require(cachedModels.first { $0.key != first.key })
                var freshModels = [
                    first.key: Self.model("unpriced", priced: false),
                    "codexbar-fallback:\(first.key):\(first.value.normalizedID)": other.value,
                ]
                if duplicate { freshModels["duplicate"] = other.value }
                let fresh = ModelsDevCatalog(providers: ["openai": Self.provider(freshModels)])
                let cached = ModelsDevCatalog(providers: ["openai": Self.provider(cachedModels)])
                let merged = fresh.mergingFallbackPricing(from: cached)
                #expect(merged == Self.legacyMerge(fresh, cached))
                #expect(merged.providers["openai"]?.models[other.key] == (duplicate ? nil : other.value))
            }
        }
    }

    @Test
    func `lookup preserves direct key candidate and duplicate ordering`() {
        let (fresh, cached) = Self.catalogs()
        let merged = fresh.mergingFallbackPricing(from: cached)
        let duplicateIDs = Self.provider([
            "first": Self.model(" normalized-only ", rate: 7),
            "second": Self.model("normalized-only", rate: 9),
            "unpriced": Self.model("normalized-only", priced: false),
            "synthetic-1": Self.model("direct-target", rate: 77),
            "normalized": Self.model("synthetic-1", rate: 5),
        ])
        for provider in Array(merged.providers.values) + [duplicateIDs] {
            let queries = provider.models.values.map(\.id) + [
                "openai/synthetic-1", "synthetic-2@20250101", "claude-synthetic-3-v1:0",
                "us.anthropic.claude-missing-20250101-v1:0", "missing",
            ]
            for query in queries {
                for exact in [false, true] {
                    #expect(provider.pricing(modelID: query, exactModelID: exact)
                        == Self.legacyPricing(provider, modelID: query, exact: exact))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func `normalized lookup preserves catalog Unicode spelling`(exact: Bool) throws {
        let provider = Self.provider(["opaque": Self.model("synthetic-e\u{301}")])
        let query = "synthetic-é"
        let actual = try #require(provider.pricing(modelID: query, exactModelID: exact))
        let expected = try #require(Self.legacyPricing(provider, modelID: query, exact: exact))
        #expect(Array(actual.normalizedModelID.utf8) == Array(expected.normalizedModelID.utf8))
    }

    @Test
    func `compiled regexes preserve legacy candidates and stable identities`() {
        let bases = [
            "",
            "synthetic",
            "claude-synthetic",
            "openai/synthetic",
            "anthropic.claude-synthetic",
            "us.anthropic.claude-synthetic",
            "🤖-synthetic",
            "synthetic-e\u{301}",
        ]
        let suffixes = [
            "",
            "@default",
            "@20250101",
            "@٢٠٢٥٠١٠١",
            "@２０２５０１０１",
            "@2025010",
            "@202501011",
            "@20250101\n",
            "@20250101\ntrailing",
            "-2025-01-01",
            "-٢٠٢٥-٠١-٠١",
            "-20250101",
            "-v1:0",
            "-v١:٢",
            "-v1:0\n",
            "-20250101-v1:0",
            "@20250101-v1:0",
            "-v1:0\u{301}",
            "-v1:0\u{2028}",
        ]
        for base in bases {
            for suffix in suffixes {
                for raw in [base + suffix, " \t" + base + suffix + "\r\n"] {
                    #expect(ModelsDevModelIDNormalizer.stableIdentity(raw)
                        == LegacyModelsDevModelIDNormalizer.stableIdentity(raw))
                    for preserve in [false, true] {
                        #expect(ModelsDevModelIDNormalizer.candidates(raw, preserveDatedSnapshots: preserve)
                            == LegacyModelsDevModelIDNormalizer.candidates(raw, preserveDatedSnapshots: preserve))
                    }
                }
            }
        }
    }

    private static func model(_ id: String, priced: Bool = true, rate: Double = 1) -> ModelsDevModel {
        ModelsDevModel(id: id, name: id, cost: ModelsDevCost(input: priced ? rate : nil, output: rate * 2))
    }

    private static func provider(_ models: [String: ModelsDevModel]) -> ModelsDevProvider {
        ModelsDevProvider(id: nil, name: "Synthetic provider", models: models, mapKey: "openai")
    }

    private static func catalogs() -> (ModelsDevCatalog, ModelsDevCatalog) {
        var fresh: [String: ModelsDevProvider] = [:]
        var cached: [String: ModelsDevProvider] = [:]
        for providerID in ["openai", "anthropic", "synthetic"] {
            var freshModels: [String: ModelsDevModel] = [:]
            var cachedModels: [String: ModelsDevModel] = [:]
            for index in 0..<160 {
                let base = "synthetic-\(index)"
                let aliases = [
                    base,
                    "openai/\(base)",
                    "\(base)@20250101",
                    "\(base)-20250101",
                    "\(base)-2025-01-01",
                    "\(base)-v1:0",
                    "claude-\(base)@default",
                    " \(base) ",
                ]
                cachedModels[base] = self.model(aliases[index % aliases.count], priced: index % 7 != 0)
                cachedModels["duplicate-\(index)"] = cachedModels[base]
                if index % 3 != 0 {
                    freshModels[base] = self.model(base, priced: index % 5 != 0, rate: 99)
                }
            }
            fresh[providerID] = self.provider(freshModels)
            cached[providerID] = self.provider(cachedModels)
        }
        cached["removed"] = self.provider(["only": self.model("removed")])
        return (ModelsDevCatalog(providers: fresh), ModelsDevCatalog(providers: cached))
    }

    private static func legacyMerge(
        _ fresh: ModelsDevCatalog,
        _ cached: ModelsDevCatalog,
        stableIdentity: (String) -> String = ModelsDevModelIDNormalizer.stableIdentity) -> ModelsDevCatalog
    {
        var merged = fresh
        for (providerID, cachedProvider) in cached.providers {
            let normalizedProviderID = ModelsDevProvider.normalizeProviderID(providerID)
            guard var provider = merged.providers[normalizedProviderID] else {
                merged.providers[normalizedProviderID] = cachedProvider
                continue
            }
            for (modelKey, cachedModel) in cachedProvider.models where cachedModel.isPriceable {
                let identity = stableIdentity(cachedModel.id)
                guard !provider.models.values.contains(where: {
                    $0.isPriceable && stableIdentity($0.id) == identity
                }) else { continue }
                let fallbackKey = provider.models[modelKey] == nil
                    ? modelKey
                    : "codexbar-fallback:\(modelKey):\(cachedModel.normalizedID)"
                provider.models[fallbackKey] = cachedModel
            }
            merged.providers[normalizedProviderID] = provider
        }
        return merged
    }

    private static func legacyPricing(
        _ provider: ModelsDevProvider,
        modelID: String,
        exact: Bool) -> ModelsDevPricingLookup?
    {
        let candidates = exact ? [ModelsDevModelIDNormalizer.normalize(modelID)]
            : ModelsDevModelIDNormalizer.candidates(modelID)
        for candidate in candidates {
            if let model = provider.models[candidate],
               let pricing = model.pricing(
                   providerID: provider.id ?? provider.mapKey ?? "",
                   providerName: provider.name)
            {
                return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: candidate)
            }
            for match in provider.models.values where match.normalizedID == candidate {
                if let pricing = match.pricing(
                    providerID: provider.id ?? provider.mapKey ?? "",
                    providerName: provider.name)
                {
                    return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: match.normalizedID)
                }
            }
        }
        return nil
    }
}

/// Frozen pre-index normalizer: covers ICU digit, anchor, and Unicode range behavior.
private enum LegacyModelsDevModelIDNormalizer {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stableIdentity(_ raw: String) -> String {
        let normalized = self.normalize(raw)
        if let atSign = normalized.firstIndex(of: "@") {
            let base = String(normalized[..<atSign])
            let suffix = String(normalized[normalized.index(after: atSign)...])
            if suffix.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
                return "\(self.canonicalAliasIdentity(base))-\(suffix)"
            }
        }

        return self.canonicalAliasIdentity(normalized)
    }

    private static func canonicalAliasIdentity(_ raw: String) -> String {
        self.candidates(raw, preserveDatedSnapshots: true).reversed().lazy
            .map { candidate in
                guard candidate.hasSuffix("@default") else { return candidate }
                return String(candidate.dropLast("@default".count))
            }
            .first { !$0.isEmpty } ?? self.normalize(raw)
    }

    static func candidates(_ raw: String, preserveDatedSnapshots: Bool = false) -> [String] {
        var candidates: [String] = []

        func append(_ value: String) {
            let normalized = self.normalize(value)
            guard !normalized.isEmpty, !candidates.contains(normalized) else { return }
            candidates.append(normalized)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        append(trimmed)

        if trimmed.hasPrefix("openai/") {
            append(String(trimmed.dropFirst("openai/".count)))
        }

        if trimmed.hasPrefix("anthropic.") {
            append(String(trimmed.dropFirst("anthropic.".count)))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                append(tail)
            }
        }

        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            if let atSign = candidate.firstIndex(of: "@") {
                let base = String(candidate[..<atSign])
                let suffix = String(candidate[candidate.index(after: atSign)...])
                if suffix.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
                    append("\(base)-\(suffix)")
                }
                append(base)
            } else if candidate.hasPrefix("claude-") {
                append("\(candidate)@default")
            }

            if !preserveDatedSnapshots {
                if let dated = candidate.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
                    append(String(candidate[..<dated.lowerBound]))
                }
                if let compactDate = candidate.range(of: #"-\d{8}$"#, options: .regularExpression) {
                    append(String(candidate[..<compactDate.lowerBound]))
                }
            }
            if let version = candidate.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
                var base = candidate
                base.removeSubrange(version)
                append(base)
            }

            index += 1
        }

        return candidates
    }
}
