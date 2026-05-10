import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ModelsDevPricingInfo: Codable, Equatable, Sendable {
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

struct ModelsDevPricingLookup: Equatable, Sendable {
    var pricing: ModelsDevPricingInfo
    var normalizedModelID: String
}

struct ModelsDevCatalog: Codable, Equatable, Sendable {
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

    func containsProviderIDs(_ providerIDs: some Sequence<String>) -> Bool {
        providerIDs.allSatisfy { self.providers.keys.contains(ModelsDevProvider.normalizeProviderID($0)) }
    }

    func containsProviderModels(from cachedCatalog: ModelsDevCatalog) -> Bool {
        cachedCatalog.providers.allSatisfy { providerID, cachedProvider in
            guard let provider = self.providers[ModelsDevProvider.normalizeProviderID(providerID)] else { return false }
            return cachedProvider.models.values
                .filter(\.isPriceable)
                .allSatisfy { provider.containsModel(matching: $0) }
        }
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

struct ModelsDevProvider: Codable, Equatable, Sendable {
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
        }

        for candidate in candidates {
            if let match = self.models.values.first(where: { $0.normalizedID == candidate }),
               let pricing = match.pricing(providerID: self.id ?? self.mapKey ?? "", providerName: self.name)
            {
                return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: match.normalizedID)
            }
        }

        return nil
    }

    func containsModel(matching cachedModel: ModelsDevModel) -> Bool {
        self.pricing(modelID: cachedModel.id) != nil
    }
}

struct ModelsDevModel: Codable, Equatable, Sendable {
    var id: String
    var name: String?
    var cost: ModelsDevCost?
    var limit: ModelsDevLimit?

    var normalizedID: String {
        ModelsDevModelIDNormalizer.normalize(self.id)
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

struct ModelsDevCost: Codable, Equatable, Sendable {
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

struct ModelsDevContextOver200KCost: Codable, Equatable, Sendable {
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

struct ModelsDevLimit: Codable, Equatable, Sendable {
    var context: Int?
}

enum ModelsDevModelIDNormalizer {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func candidates(_ raw: String) -> [String] {
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
                append(base)
                let suffix = String(candidate[candidate.index(after: atSign)...])
                if suffix.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
                    append("\(base)-\(suffix)")
                }
            } else if candidate.hasPrefix("claude-") {
                append("\(candidate)@default")
            }

            if let dated = candidate.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
                append(String(candidate[..<dated.lowerBound]))
            }
            if let compactDate = candidate.range(of: #"-\d{8}$"#, options: .regularExpression) {
                append(String(candidate[..<compactDate.lowerBound]))
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

struct ModelsDevCacheArtifact: Codable, Equatable, Sendable {
    var version: Int
    var fetchedAt: Date
    var catalog: ModelsDevCatalog
}

struct ModelsDevCacheLoadResult: Equatable, Sendable {
    var artifact: ModelsDevCacheArtifact?
    var isStale: Bool
    var error: ModelsDevCache.Error?
}

enum ModelsDevCache {
    enum Error: Swift.Error, Equatable, Sendable {
        case unreadable
        case invalidVersion
        case invalidJSON
    }

    static let artifactVersion = 1
    static let ttlSeconds: TimeInterval = 24 * 60 * 60

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
        guard let data = try? Data(contentsOf: url) else {
            return ModelsDevCacheLoadResult(artifact: nil, isStale: true, error: .unreadable)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ModelsDevCacheArtifact.self, from: data) else {
            return ModelsDevCacheLoadResult(artifact: nil, isStale: true, error: .invalidJSON)
        }
        guard decoded.version == Self.artifactVersion else {
            return ModelsDevCacheLoadResult(artifact: nil, isStale: true, error: .invalidVersion)
        }

        return ModelsDevCacheLoadResult(
            artifact: decoded,
            isStale: now.timeIntervalSince(decoded.fetchedAt) > Self.ttlSeconds,
            error: nil)
    }

    static func save(catalog: ModelsDevCatalog, fetchedAt: Date = Date(), cacheRoot: URL? = nil) {
        let artifact = ModelsDevCacheArtifact(
            version: Self.artifactVersion,
            fetchedAt: fetchedAt,
            catalog: catalog)
        self.save(artifact: artifact, cacheRoot: cacheRoot)
    }

    static func save(artifact: ModelsDevCacheArtifact, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(artifact) else { return }

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
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
    enum Error: Swift.Error, Equatable, Sendable {
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

enum ModelsDevPricingPipeline {
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

        do {
            let catalog = try await client.fetchCatalog()
            if let oldCatalog = load.artifact?.catalog,
               !catalog.containsProviderModels(from: oldCatalog)
            {
                return
            }
            ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: cacheRoot)
        } catch {
            // Best-effort refresh only. Future scanner integration should keep using the last valid cache.
        }
    }
}
