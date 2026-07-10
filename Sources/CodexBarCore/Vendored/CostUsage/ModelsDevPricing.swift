import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ModelsDevPricingInfo: Codable, Equatable {
    var providerID: String
    var providerName: String?
    var modelID: String
    var modelName: String?
    var inputCostPerToken: Double
    var outputCostPerToken: Double
    var cacheReadInputCostPerToken: Double?
    var cacheCreationInputCostPerToken: Double?
    var contextWindow: Int?
    var thresholdTokens: Int?
    var inputCostPerTokenAboveThreshold: Double?
    var outputCostPerTokenAboveThreshold: Double?
    var cacheReadInputCostPerTokenAboveThreshold: Double?
    var cacheCreationInputCostPerTokenAboveThreshold: Double?
}

struct ModelsDevPricingLookup: Equatable {
    var pricing: ModelsDevPricingInfo
    var normalizedModelID: String
}

struct ModelsDevCatalog: Codable, Equatable {
    var providers: [String: ModelsDevProvider]

    init(providers: [String: ModelsDevProvider]) {
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ModelsDevAnyCodingKey.self)
        if let providersKey = ModelsDevAnyCodingKey(stringValue: "providers"),
           let decoded = try? container.decode([String: ModelsDevProvider].self, forKey: providersKey)
        {
            self.providers = decoded.reduce(into: [:]) { result, item in
                var provider = item.value
                provider.mapKey = provider.mapKey ?? item.key
                let providerID = ModelsDevProvider.normalizeProviderID(provider.id ?? item.key)
                result[providerID] = provider
            }
            return
        }

        var providers: [String: ModelsDevProvider] = [:]

        for key in container.allKeys {
            guard var provider = try? container.decode(ModelsDevProvider.self, forKey: key) else { continue }
            provider.mapKey = key.stringValue
            let providerID = ModelsDevProvider.normalizeProviderID(provider.id ?? key.stringValue)
            providers[providerID] = provider
        }

        self.providers = providers
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ModelsDevAnyCodingKey.self)
        try container.encode(self.providers, forKey: ModelsDevAnyCodingKey(stringValue: "providers")!)
    }

    func pricing(providerID rawProviderID: String, modelID rawModelID: String) -> ModelsDevPricingLookup? {
        let providerID = ModelsDevProvider.normalizeProviderID(rawProviderID)
        return self.providers[providerID]?.pricing(modelID: rawModelID)
    }

    func isPlausibleRefresh() -> Bool {
        // These are the direct pricing sources CodexBar relies on. Requiring both
        // rejects empty/partial responses without comparing against a fallback-
        // enriched cache that intentionally grows as models.dev churns.
        ["anthropic", "openai"].allSatisfy { providerID in
            self.providers[providerID]?.models.values.contains(where: \.isPriceable) == true
        }
    }

    func mergingFallbackPricing(from cachedCatalog: ModelsDevCatalog) -> ModelsDevCatalog {
        var merged = self
        for (providerID, cachedProvider) in cachedCatalog.providers {
            let normalizedProviderID = ModelsDevProvider.normalizeProviderID(providerID)
            guard var provider = merged.providers[normalizedProviderID] else {
                merged.providers[normalizedProviderID] = cachedProvider
                continue
            }

            for (modelKey, cachedModel) in cachedProvider.models
                where cachedModel.isPriceable && !provider.containsPricedModel(
                    withStableIdentity: cachedModel.stableIdentity)
            {
                let fallbackKey = provider.models[modelKey] == nil
                    ? modelKey
                    : "codexbar-fallback:\(modelKey):\(cachedModel.normalizedID)"
                provider.models[fallbackKey] = cachedModel
            }
            merged.providers[normalizedProviderID] = provider
        }
        return merged
    }
}

private struct ModelsDevAnyCodingKey: CodingKey {
    var intValue: Int?
    var stringValue: String

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }

    init?(stringValue: String) {
        self.intValue = nil
        self.stringValue = stringValue
    }
}

struct ModelsDevProvider: Codable, Equatable {
    var id: String?
    var name: String?
    var models: [String: ModelsDevModel]
    var mapKey: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case models
    }

    init(id: String?, name: String?, models: [String: ModelsDevModel], mapKey: String? = nil) {
        self.id = id
        self.name = name
        self.models = models
        self.mapKey = mapKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)

        let modelContainer = try container.nestedContainer(keyedBy: ModelsDevAnyCodingKey.self, forKey: .models)
        var models: [String: ModelsDevModel] = [:]
        for key in modelContainer.allKeys {
            guard let model = try? modelContainer.decode(ModelsDevModel.self, forKey: key) else { continue }
            models[key.stringValue] = model
        }
        self.models = models
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.id, forKey: .id)
        try container.encodeIfPresent(self.name, forKey: .name)
        try container.encode(self.models, forKey: .models)
    }

    static func normalizeProviderID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func pricing(modelID rawModelID: String) -> ModelsDevPricingLookup? {
        let candidates = ModelsDevModelIDNormalizer.candidates(rawModelID)
        for candidate in candidates {
            if let model = self.models[candidate],
               let pricing = model.pricing(providerID: self.id ?? self.mapKey ?? "", providerName: self.name)
            {
                return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: candidate)
            }

            for match in self.models.values where match.normalizedID == candidate {
                if let pricing = match.pricing(providerID: self.id ?? self.mapKey ?? "", providerName: self.name) {
                    return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: match.normalizedID)
                }
            }
        }

        return nil
    }

    func containsPricedModel(withStableIdentity modelID: String) -> Bool {
        self.models.values.contains { model in
            model.isPriceable && model.stableIdentity == modelID
        }
    }
}

struct ModelsDevModel: Codable, Equatable {
    var id: String
    var name: String?
    var cost: ModelsDevCost?
    var limit: ModelsDevLimit?

    var normalizedID: String {
        ModelsDevModelIDNormalizer.normalize(self.id)
    }

    var stableIdentity: String {
        ModelsDevModelIDNormalizer.stableIdentity(self.id)
    }

    var isPriceable: Bool {
        self.cost?.input != nil && self.cost?.output != nil
    }

    func pricing(providerID: String, providerName: String?) -> ModelsDevPricingInfo? {
        guard let input = self.cost?.input, let output = self.cost?.output else { return nil }

        // models.dev publishes USD per 1M tokens. CodexBar cost math uses USD per token.
        let unit = 1_000_000.0
        let contextOver200K = self.cost?.contextOver200K
        return ModelsDevPricingInfo(
            providerID: ModelsDevProvider.normalizeProviderID(providerID),
            providerName: providerName,
            modelID: self.id,
            modelName: self.name,
            inputCostPerToken: input / unit,
            outputCostPerToken: output / unit,
            cacheReadInputCostPerToken: self.cost?.cacheRead.map { $0 / unit },
            cacheCreationInputCostPerToken: self.cost?.cacheWrite.map { $0 / unit },
            contextWindow: self.limit?.context,
            thresholdTokens: contextOver200K == nil ? nil : 200_000,
            inputCostPerTokenAboveThreshold: contextOver200K?.input.map { $0 / unit },
            outputCostPerTokenAboveThreshold: contextOver200K?.output.map { $0 / unit },
            cacheReadInputCostPerTokenAboveThreshold: contextOver200K?.cacheRead.map { $0 / unit },
            cacheCreationInputCostPerTokenAboveThreshold: contextOver200K?.cacheWrite.map { $0 / unit })
    }
}

struct ModelsDevCost: Codable, Equatable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
    var contextOver200K: ModelsDevContextOver200KCost?

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case contextOver200K = "context_over_200k"
    }
}

struct ModelsDevContextOver200KCost: Codable, Equatable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

struct ModelsDevLimit: Codable, Equatable {
    var context: Int?
}

enum ModelsDevModelIDNormalizer {
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

struct ModelsDevCacheArtifact: Codable, Equatable {
    var version: Int
    var fetchedAt: Date
    var catalog: ModelsDevCatalog
}

struct ModelsDevCacheLoadResult: Equatable {
    var artifact: ModelsDevCacheArtifact?
    var isStale: Bool
    var error: ModelsDevCache.Error?
}

/// In-memory memo for the decoded models.dev catalog, keyed by file path + on-disk identity.
///
/// `ModelsDevCache.load` is called once per usage row whenever a cost lookup is performed without a
/// pre-resolved catalog (see `CostUsagePricing.modelsDevLookup`). Without this memo, scanning a large
/// `~/.codex` history re-reads and re-decodes the ~800 KB catalog JSON for every row, which pegs the CPU
/// and freezes the menu during a refresh.
///
/// The full load *outcome* is memoized, not just successful decodes: a corrupt or wrong-version cache is
/// read and decode-attempted exactly as expensively as a valid one, so caching only successes would leave
/// the per-row storm in place whenever the cache is unreadable. Reusing the outcome while the file is
/// unchanged keeps every fallback path cheap.
private final class ModelsDevCacheMemo: @unchecked Sendable {
    enum Outcome {
        case decoded(ModelsDevCacheArtifact)
        case failure(ModelsDevCache.Error)
    }

    private struct Entry {
        let modificationDate: Date?
        let size: Int?
        let outcome: Outcome
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func outcome(path: String, modificationDate: Date?, size: Int?) -> Outcome? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[path],
              entry.modificationDate == modificationDate,
              entry.size == size
        else {
            return nil
        }
        return entry.outcome
    }

    func store(path: String, modificationDate: Date?, size: Int?, outcome: Outcome) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[path] = Entry(modificationDate: modificationDate, size: size, outcome: outcome)
    }

    func invalidate(path: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeValue(forKey: path)
    }
}

enum ModelsDevCache {
    enum Error: Swift.Error, Equatable {
        case unreadable
        case invalidVersion
        case invalidJSON
    }

    static let artifactVersion = 1
    static let ttlSeconds: TimeInterval = 24 * 60 * 60

    private static let memo = ModelsDevCacheMemo()

    private static func fileMetadata(at url: URL) -> (modificationDate: Date?, size: Int?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, nil)
        }
        let modificationDate = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue
        return (modificationDate, size)
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("model-pricing", isDirectory: true)
            .appendingPathComponent("models-dev-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCacheLoadResult {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let metadata = Self.fileMetadata(at: url)

        // Staleness depends on `now`, so the result is always rebuilt; only the read+decode outcome is memoized.
        if let outcome = Self.memo.outcome(
            path: url.path,
            modificationDate: metadata.modificationDate,
            size: metadata.size)
        {
            return Self.result(for: outcome, now: now)
        }

        let outcome = Self.readOutcome(at: url)
        Self.memo.store(
            path: url.path,
            modificationDate: metadata.modificationDate,
            size: metadata.size,
            outcome: outcome)
        return Self.result(for: outcome, now: now)
    }

    private static func readOutcome(at url: URL) -> ModelsDevCacheMemo.Outcome {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ModelsDevCacheArtifact.self, from: data) else {
            return .failure(.invalidJSON)
        }
        guard decoded.version == Self.artifactVersion else {
            return .failure(.invalidVersion)
        }
        return .decoded(decoded)
    }

    private static func result(for outcome: ModelsDevCacheMemo.Outcome, now: Date) -> ModelsDevCacheLoadResult {
        switch outcome {
        case let .decoded(artifact):
            ModelsDevCacheLoadResult(
                artifact: artifact,
                isStale: now.timeIntervalSince(artifact.fetchedAt) > Self.ttlSeconds,
                error: nil)
        case let .failure(error):
            ModelsDevCacheLoadResult(artifact: nil, isStale: true, error: error)
        }
    }

    @discardableResult
    static func save(catalog: ModelsDevCatalog, fetchedAt: Date = Date(), cacheRoot: URL? = nil) -> Bool {
        let artifact = ModelsDevCacheArtifact(
            version: Self.artifactVersion,
            fetchedAt: fetchedAt,
            catalog: catalog)
        return self.save(artifact: artifact, cacheRoot: cacheRoot)
    }

    @discardableResult
    static func save(artifact: ModelsDevCacheArtifact, cacheRoot: URL? = nil) -> Bool {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(artifact) else { return false }

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            // The on-disk catalog changed; drop the memo so the next load decodes the fresh file.
            Self.memo.invalidate(path: url.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

protocol ModelsDevHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionModelsDevTransport: ModelsDevHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

struct ModelsDevClient: Sendable {
    enum Error: Swift.Error, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case invalidJSON
    }

    var url: URL
    var transport: any ModelsDevHTTPTransport

    init(
        url: URL = URL(string: "https://models.dev/api.json")!,
        transport: any ModelsDevHTTPTransport = URLSessionModelsDevTransport())
    {
        self.url = url
        self.transport = transport
    }

    func fetchCatalog() async throws -> ModelsDevCatalog {
        var request = URLRequest(url: self.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await self.transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Error.httpStatus(http.statusCode) }

        do {
            return try JSONDecoder().decode(ModelsDevCatalog.self, from: data)
        } catch {
            throw Error.invalidJSON
        }
    }
}

enum ModelsDevUnknownModelRefreshOutcome: Equatable {
    case pricingAvailable
    case unavailable
}

private let modelsDevCatalogRetryInterval: TimeInterval = 15 * 60

enum ModelsDevPricingPipeline {
    private static let refreshCoordinator = ModelsDevRefreshCoordinator()

    static func lookup(
        providerID: String,
        modelID: String,
        now: Date = Date(),
        cacheRoot: URL? = nil) -> ModelsDevPricingLookup?
    {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot)
            .artifact?
            .catalog
            .pricing(providerID: providerID, modelID: modelID)
    }

    static func refreshIfNeeded(
        now: Date = Date(),
        cacheRoot: URL? = nil,
        client: ModelsDevClient = ModelsDevClient()) async
    {
        let load = ModelsDevCache.load(now: now, cacheRoot: cacheRoot)
        guard load.isStale else { return }

        let cachePath = ModelsDevCache.cacheFileURL(cacheRoot: cacheRoot).standardizedFileURL.path
        _ = await self.refreshCoordinator.refresh(
            cachePath: cachePath,
            now: now)
        {
            await self.refreshStaleCache(now: now, cacheRoot: cacheRoot, client: client)
        }
    }

    static func refreshForUnknownModelsIfNeeded(
        providerID: String,
        modelIDs: Set<String>,
        now: Date = Date(),
        cacheRoot: URL? = nil,
        client: ModelsDevClient = ModelsDevClient()) async -> ModelsDevUnknownModelRefreshOutcome
    {
        guard !modelIDs.isEmpty else { return .unavailable }
        let load = ModelsDevCache.load(now: now, cacheRoot: cacheRoot)
        let unknownModelIDs = modelIDs.filter {
            load.artifact?.catalog.pricing(providerID: providerID, modelID: $0) == nil
        }
        guard !unknownModelIDs.isEmpty else { return .pricingAvailable }
        if let fetchedAt = load.artifact?.fetchedAt,
           now.timeIntervalSince(fetchedAt) < modelsDevCatalogRetryInterval
        {
            return .unavailable
        }

        let cachePath = ModelsDevCache.cacheFileURL(cacheRoot: cacheRoot).standardizedFileURL.path
        _ = await self.refreshCoordinator.refresh(
            cachePath: cachePath,
            now: now)
        {
            await self.performRefresh(now: now, cacheRoot: cacheRoot, client: client)
        }

        let refreshedCatalog = ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
        let pricingBecameAvailable = unknownModelIDs.contains {
            refreshedCatalog?.pricing(providerID: providerID, modelID: $0) != nil
        }
        return pricingBecameAvailable ? .pricingAvailable : .unavailable
    }

    private static func performRefresh(
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) async -> Bool
    {
        do {
            let catalog = try await client.fetchCatalog()
            guard catalog.isPlausibleRefresh() else { return false }
            let oldCatalog = ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
            let refreshedCatalog = oldCatalog.map { catalog.mergingFallbackPricing(from: $0) } ?? catalog
            return ModelsDevCache.save(catalog: refreshedCatalog, fetchedAt: now, cacheRoot: cacheRoot)
        } catch {
            return false
        }
    }

    static func refreshStaleCache(
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) async -> Bool
    {
        guard ModelsDevCache.load(now: now, cacheRoot: cacheRoot).isStale else { return true }
        return await self.performRefresh(now: now, cacheRoot: cacheRoot, client: client)
    }
}

private actor ModelsDevRefreshCoordinator {
    private struct InFlightRefresh {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private var inFlightByCachePath: [String: InFlightRefresh] = [:]
    private var lastCatalogAttemptByCachePath: [String: Date] = [:]

    func refresh(
        cachePath: String,
        now: Date,
        operation: @escaping @Sendable () async -> Bool) async -> Bool
    {
        if let inFlight = self.inFlightByCachePath[cachePath] {
            return await inFlight.task.value
        }
        if let lastAttempt = self.lastCatalogAttemptByCachePath[cachePath],
           now.timeIntervalSince(lastAttempt) < modelsDevCatalogRetryInterval
        {
            return false
        }
        self.lastCatalogAttemptByCachePath[cachePath] = now

        let inFlight = InFlightRefresh(
            id: UUID(),
            task: Task { await operation() })
        self.inFlightByCachePath[cachePath] = inFlight
        let result = await inFlight.task.value
        if self.inFlightByCachePath[cachePath]?.id == inFlight.id {
            self.inFlightByCachePath[cachePath] = nil
        }
        return result
    }
}
