import Foundation

extension CostUsagePricing {
    /// One synchronous report collection owns one immutable catalog and bounded exact-input memos.
    /// Dates, token thresholds, custom overlays and priority multipliers stay in the scalar pricing path.
    final class CodexResolver {
        static let memoEntryLimit = 1024

        private struct LookupResult {
            let value: ModelsDevPricingLookup?
        }

        private let catalog: ModelsDevCatalog
        // Swift String equality folds canonically equivalent spellings; keep serialized model bytes exact.
        private var normalizedModels: [[UInt8]: String] = [:]
        private var lookups: [[UInt8]: LookupResult] = [:]

        init(catalog: ModelsDevCatalog) {
            self.catalog = catalog
        }

        func normalize(_ model: String) -> String {
            let key = Array(model.utf8)
            if let value = self.normalizedModels[key] { return value }
            let value = CostUsagePricing.normalizeCodexModel(model)
            if self.normalizedModels.count < Self.memoEntryLimit {
                self.normalizedModels[key] = value
            }
            return value
        }

        func lookup(_ model: String) -> ModelsDevPricingLookup? {
            let key = Array(model.utf8)
            if let result = self.lookups[key] { return result.value }
            let value = CostUsagePricing.codexModelsDevLookup(model: model, catalog: self.catalog, cacheRoot: nil)
            if self.lookups.count < Self.memoEntryLimit {
                self.lookups[key] = LookupResult(value: value)
            }
            return value
        }
    }

    #if DEBUG
    @TaskLocal static var codexPricingWorkRecorder: CodexPricingWorkRecorder?

    final class CodexPricingWorkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lookups = 0

        var catalogLookups: Int {
            self.lock.withLock { self.lookups }
        }

        func recordCatalogLookup() {
            self.lock.withLock { self.lookups += 1 }
        }
    }
    #endif
}
