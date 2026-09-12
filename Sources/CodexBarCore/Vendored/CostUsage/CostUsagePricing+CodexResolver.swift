import Foundation

extension CostUsagePricing {
    /// One synchronous report collection owns one immutable catalog and bounded exact-input memos.
    /// Dates, token thresholds, custom overlays and priority multipliers stay in the scalar pricing path.
    final class CodexResolver {
        static let memoEntryLimit = 1024
        static let memoKeyByteLimit = 512

        private struct LookupResult {
            let value: ModelsDevPricingLookup?
        }

        private let catalog: ModelsDevCatalog
        // Swift String equality folds canonically equivalent spellings; keep serialized model bytes exact.
        private var normalizedModels: [[UInt8]: String] = [:]
        private var lookups: [[UInt8]: LookupResult] = [:]

        #if DEBUG
        var memoizedKeyByteCountForTesting: Int {
            self.normalizedModels.keys.reduce(0) { $0 + $1.count }
                + self.lookups.keys.reduce(0) { $0 + $1.count }
        }
        #endif

        init(catalog: ModelsDevCatalog) {
            self.catalog = catalog
        }

        func normalize(_ model: String) -> String {
            let key = Self.memoKey(model)
            if let key, let value = self.normalizedModels[key] { return value }
            let value = CostUsagePricing.normalizeCodexModel(model)
            if let key, self.normalizedModels.count < Self.memoEntryLimit {
                self.normalizedModels[key] = value
            }
            return value
        }

        func lookup(_ model: String) -> ModelsDevPricingLookup? {
            let key = Self.memoKey(model)
            if let key, let result = self.lookups[key] { return result.value }
            let value = CostUsagePricing.codexModelsDevLookup(model: model, catalog: self.catalog, cacheRoot: nil)
            if let key, self.lookups.count < Self.memoEntryLimit {
                self.lookups[key] = LookupResult(value: value)
            }
            return value
        }

        private static func memoKey(_ model: String) -> [UInt8]? {
            // Count before allocating: transcript-controlled identifiers can be much larger than real model IDs.
            guard model.utf8.count <= self.memoKeyByteLimit else { return nil }
            return Array(model.utf8)
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
