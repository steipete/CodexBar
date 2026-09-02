import Foundation

struct CLIProxyAPIAttributionResolver: Sendable {
    struct Observation: Sendable, Equatable {
        let sourceID: String?
        let sessionID: String
        let model: String
        let timestamp: Date?

        init(sourceID: String? = nil, sessionID: String, model: String, timestamp: Date?) {
            self.sourceID = sourceID
            self.sessionID = sessionID
            self.model = model
            self.timestamp = timestamp
        }
    }

    struct AuthProvider: Sendable, Equatable, Hashable {
        let provider: String
        let authType: CostUsageAttribution.Upstream.AuthType
    }

    struct TokenSignature: Sendable, Equatable {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let output: Int
    }

    struct Request: Sendable {
        let model: String
        let modelProvider: CostUsageAttribution.ModelProvider
        let sessionID: String?
        let timestampUnixMs: Int64?
        let tokens: TokenSignature?
        let occurrenceID: String?

        init(
            model: String,
            modelProvider: CostUsageAttribution.ModelProvider,
            sessionID: String?,
            timestampUnixMs: Int64?,
            tokens: TokenSignature?,
            occurrenceID: String? = nil)
        {
            self.model = model
            self.modelProvider = modelProvider
            self.sessionID = sessionID
            self.timestampUnixMs = timestampUnixMs
            self.tokens = tokens
            self.occurrenceID = occurrenceID
        }
    }

    private struct ObservationKey: Hashable {
        let sourceID: String?
        let sessionID: String
        let canonicalModel: String
        let timestamp: Date?
    }

    private struct UsageRecordKey: Hashable {
        let sourceID: Int
    }

    private struct IndexedUsageRecord {
        let sourceID: Int
        let record: CLIProxyAPIUsageRecord
    }

    private struct UsageRecordMatch {
        let key: UsageRecordKey
        let record: CLIProxyAPIUsageRecord
    }

    private static let requestBodyMarker = "=== REQUEST BODY ==="
    private static let responseMarkers = ["=== API RESPONSE ===", "=== RESPONSE ==="]
    private static let maxLogPrefixBytes = 2 * 1024 * 1024
    private static let maximumRouteMatchDistance: TimeInterval = 60 * 60
    private static let maximumTelemetryMatchDistance: TimeInterval = 5
    private static let maximumTelemetryOnlyMatchDistance: TimeInterval = 30
    private static let observationCache = ObservationCache()

    private let observationsBySessionID: [String: [Observation]]
    private let observationsByCanonicalModel: [String: [Observation]]
    private let usageRecordsByCanonicalModel: [String: [IndexedUsageRecord]]
    private let authProviders: [AuthProvider]
    private let codexOAuthModelRoutes: [String: String]
    private let hasConfiguredOpenAIAPIUpstream: Bool
    let inputArtifactFingerprint: [String: CostUsageClaudeFileStamp]

    init(
        observations: [Observation],
        usageRecords: [CLIProxyAPIUsageRecord] = [],
        authProviders: [AuthProvider] = [],
        codexOAuthModelAliases: [String: String] = [:],
        hasConfiguredOpenAIAPIUpstream: Bool = false,
        inputArtifactFingerprint: [String: CostUsageClaudeFileStamp] = [:])
    {
        self.observationsBySessionID = Dictionary(grouping: observations, by: \.sessionID)
        self.observationsByCanonicalModel = Dictionary(
            grouping: observations,
            by: { Self.canonicalModel($0.model) })
        self.usageRecordsByCanonicalModel = Self.indexUsageRecords(usageRecords)
        self.authProviders = authProviders
        self.codexOAuthModelRoutes = codexOAuthModelAliases.reduce(into: [:]) { result, entry in
            let upstreamModel = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !upstreamModel.isEmpty else { return }
            result[Self.canonicalModel(entry.key)] = upstreamModel
            result[Self.canonicalModel(upstreamModel)] = upstreamModel
        }
        self.hasConfiguredOpenAIAPIUpstream = hasConfiguredOpenAIAPIUpstream
        self.inputArtifactFingerprint = inputArtifactFingerprint
    }

    static func load(
        home: URL,
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default,
        forceReload: Bool = false,
        usageRecords: [CLIProxyAPIUsageRecord]? = nil,
        checkCancellation: (() throws -> Void)? = nil) throws -> Self
    {
        let inputArtifactFingerprint = try self.inputArtifactFingerprint(
            home: home,
            fileManager: fileManager,
            checkCancellation: checkCancellation)
        let observations = try self.loadObservations(
            logDirectory: home.appendingPathComponent("logs", isDirectory: true),
            fileManager: fileManager,
            forceReload: forceReload,
            checkCancellation: checkCancellation)
        let resolver = Self(
            observations: observations,
            usageRecords: usageRecords ?? CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot),
            authProviders: self.loadAuthProviders(home: home, fileManager: fileManager),
            codexOAuthModelAliases: self.loadCodexOAuthModelAliases(home: home, fileManager: fileManager),
            hasConfiguredOpenAIAPIUpstream: self.hasConfiguredOpenAIAPIUpstream(
                home: home,
                fileManager: fileManager),
            inputArtifactFingerprint: inputArtifactFingerprint)
        guard try inputArtifactFingerprint == self.inputArtifactFingerprint(
            home: home,
            fileManager: fileManager,
            checkCancellation: checkCancellation)
        else { throw CancellationError() }
        return resolver
    }

    func attribution(
        model: String,
        modelProvider: CostUsageAttribution.ModelProvider,
        sessionID: String?,
        timestampUnixMs: Int64?,
        tokens: TokenSignature?) -> CostUsageAttribution
    {
        let request = Request(
            model: model,
            modelProvider: modelProvider,
            sessionID: sessionID,
            timestampUnixMs: timestampUnixMs,
            tokens: tokens)
        let routeObservation = self.matchingObservation(
            model: model,
            sessionID: sessionID,
            timestampUnixMs: timestampUnixMs)
        let telemetryObservation = self.matchingObservation(
            model: model,
            sessionID: sessionID,
            timestampUnixMs: timestampUnixMs)
        let usageRecord = telemetryObservation.flatMap {
            self.matchingUsageRecord(
                observation: $0,
                model: model,
                tokens: tokens)
        }
        return self.attribution(
            request: request,
            routeObservation: routeObservation,
            usageRecord: usageRecord)
    }

    func attributions(for requests: [Request]) -> [CostUsageAttribution] {
        var prepared = requests.map { request in
            let observationCandidates = self.matchingObservations(
                model: request.model,
                sessionID: request.sessionID,
                timestampUnixMs: request.timestampUnixMs)
            let observationMatches = observationCandidates.compactMap { observation in
                self.closestUsageRecordMatch(
                    observation: observation,
                    model: request.model,
                    tokens: request.tokens)
            }
            let matchKeys = Set(observationMatches.map(\.key))
            let observationUsageRecordMatch = observationMatches.count == observationCandidates.count
                && matchKeys.count == 1
                ? observationMatches.first
                : nil
            let usageRecordMatch = observationUsageRecordMatch
                ?? (observationCandidates.isEmpty ? self.closestUsageRecordMatch(request: request) : nil)
            let observation = observationCandidates.count == 1 ? observationCandidates[0] : nil
            return (
                request: request,
                routeObservation: observation,
                telemetryObservation: observation,
                usageRecordMatch: usageRecordMatch,
                observationCandidates: observationCandidates)
        }
        var claimedObservationKeys = Set(prepared.compactMap(\.routeObservation).map(Self.observationKey))
        for index in prepared.indices where prepared[index].routeObservation == nil
            && prepared[index].usageRecordMatch != nil
        {
            let candidates = prepared[index].observationCandidates.sorted {
                ($0.sourceID ?? "") < ($1.sourceID ?? "")
            }
            guard let observation = candidates.first(where: {
                !claimedObservationKeys.contains(Self.observationKey($0))
            }) else { continue }
            prepared[index].routeObservation = observation
            prepared[index].telemetryObservation = observation
            claimedObservationKeys.insert(Self.observationKey(observation))
        }
        var routeCandidatesByObservation:
            [ObservationKey: [(index: Int, request: Request, observation: Observation)]] = [:]
        for (index, item) in prepared.enumerated() {
            guard let observation = item.routeObservation else { continue }
            routeCandidatesByObservation[Self.observationKey(observation), default: []].append(
                (index: index, request: item.request, observation: observation))
        }
        var matchClaimers: [UsageRecordKey: Set<String>] = [:]
        for (index, item) in prepared.enumerated() {
            guard let key = item.usageRecordMatch?.key else { continue }
            let claimer = item.request.occurrenceID.map { "occurrence:\($0)" } ?? "index:\(index)"
            matchClaimers[key, default: []].insert(claimer)
        }
        let matchCounts = matchClaimers.mapValues(\.count)
        var routeOwnerByObservation: [ObservationKey: Int] = [:]
        for (key, candidates) in routeCandidatesByObservation {
            if candidates.count == 1,
               let candidate = candidates.first,
               prepared[candidate.index].usageRecordMatch != nil
               || Self.isCloseRouteMatch(candidate)
            {
                routeOwnerByObservation[key] = candidate.index
            } else if candidates.count > 1,
                      let observationTimestamp = candidates.first?.observation.timestamp,
                      let candidate = Self.uniqueClosest(
                          candidates,
                          target: observationTimestamp,
                          timestamp: { Self.timestamp(for: $0.request) }),
                      prepared[candidate.index].usageRecordMatch.map({ matchCounts[$0.key] == 1 }) == true
                      || Self.isCloseRouteMatch(candidate)
            {
                routeOwnerByObservation[key] = candidate.index
            }
        }
        let representedObservations = Set(prepared.compactMap { item -> ObservationKey? in
            guard item.usageRecordMatch != nil,
                  let observation = item.telemetryObservation
            else { return nil }
            return Self.observationKey(observation)
        })

        return prepared.enumerated().map { index, item in
            let routeObservation = item.routeObservation.flatMap { observation in
                routeOwnerByObservation[Self.observationKey(observation)] == index
                    ? observation
                    : nil
            }
            let usageRecord = item.usageRecordMatch.flatMap { match -> CLIProxyAPIUsageRecord? in
                guard matchCounts[match.key] == 1,
                      self.allPlausibleObservationsRepresented(
                          for: match.record,
                          model: item.request.model,
                          representedObservations: representedObservations)
                else { return nil }
                return match.record
            }
            return self.attribution(
                request: item.request,
                routeObservation: routeObservation,
                usageRecord: usageRecord)
        }
    }

    private static func isCloseRouteMatch(
        _ candidate: (index: Int, request: Request, observation: Observation)) -> Bool
    {
        guard let requestTimestamp = timestamp(for: candidate.request),
              let observationTimestamp = candidate.observation.timestamp
        else { return false }
        return abs(requestTimestamp.timeIntervalSince(observationTimestamp)) <= Self.maximumTelemetryMatchDistance
    }

    func hasMatchingObservation(for request: Request) -> Bool {
        self.matchingObservation(
            model: request.model,
            sessionID: request.sessionID,
            timestampUnixMs: request.timestampUnixMs) != nil
    }

    private func attribution(
        request: Request,
        routeObservation: Observation?,
        usageRecord: CLIProxyAPIUsageRecord?) -> CostUsageAttribution
    {
        let canonicalModel = Self.canonicalModel(request.model)
        let configuredCodexModel = self.codexOAuthModelRoutes[canonicalModel]
        let routeObserved = routeObservation != nil || usageRecord != nil
        let resolvedModelProvider: CostUsageAttribution.ModelProvider =
            request.modelProvider == .unknown && configuredCodexModel != nil && routeObserved
                ? .openAI
                : request.modelProvider
        let inventoryUpstream = usageRecord == nil
            ? self.authInventoryUpstream(
                model: request.model,
                modelProvider: resolvedModelProvider,
                routeObserved: routeObservation != nil,
                configuredCodexModel: configuredCodexModel)
            : nil
        let routeConfirmed = routeObservation != nil || usageRecord != nil || inventoryUpstream != nil
        var evidence: Set<CostUsageAttribution.Evidence> = [.modelProvider]
        if routeObservation != nil {
            evidence.insert(.cliProxyRequestLog)
        }
        if configuredCodexModel != nil, inventoryUpstream != nil {
            evidence.insert(.cliProxyModelAlias)
        }
        if usageRecord != nil {
            evidence.insert(.cliProxyUsageTelemetry)
        }
        if inventoryUpstream != nil {
            evidence.insert(.cliProxyAuthInventory)
        }

        return CostUsageAttribution(
            client: .claudeCode,
            route: routeConfirmed ? .cliProxyAPI : .unknown,
            modelProvider: resolvedModelProvider,
            upstream: usageRecord.map(Self.upstream) ?? inventoryUpstream,
            evidence: evidence.sorted { $0.rawValue < $1.rawValue })
    }

    private func matchingObservation(
        model: String,
        sessionID: String?,
        timestampUnixMs: Int64?) -> Observation?
    {
        let candidates = self.matchingObservations(
            model: model,
            sessionID: sessionID,
            timestampUnixMs: timestampUnixMs)
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func matchingObservations(
        model: String,
        sessionID: String?,
        timestampUnixMs: Int64?) -> [Observation]
    {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              let observations = self.observationsBySessionID[sessionID]
        else { return [] }

        let canonicalModel = Self.canonicalModel(model)
        let matchingModels = observations.filter { Self.canonicalModel($0.model) == canonicalModel }
        guard !matchingModels.isEmpty else { return [] }
        guard let timestampUnixMs else {
            return matchingModels.count == 1 ? matchingModels : []
        }
        let timestamp = Date(timeIntervalSince1970: Double(timestampUnixMs) / 1000)
        let ranked = matchingModels.compactMap { observation -> (Observation, TimeInterval)? in
            guard let observationTimestamp = observation.timestamp else { return nil }
            let distance = abs(observationTimestamp.timeIntervalSince(timestamp))
            return distance <= Self.maximumRouteMatchDistance ? (observation, distance) : nil
        }
        guard let closestDistance = ranked.map(\.1).min() else { return [] }
        return ranked.filter { $0.1 == closestDistance }.map(\.0)
    }

    private static func timestamp(for request: Request) -> Date? {
        request.timestampUnixMs.map {
            Date(timeIntervalSince1970: Double($0) / 1000)
        }
    }

    private func matchingUsageRecord(
        observation: Observation,
        model: String,
        tokens: TokenSignature?) -> CLIProxyAPIUsageRecord?
    {
        let candidates = self.usageRecordMatches(
            observation: observation,
            model: model,
            tokens: tokens)
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return self.plausibleObservations(for: candidate.record, model: model).count == 1
            ? candidate.record
            : nil
    }

    private func plausibleObservations(
        for record: CLIProxyAPIUsageRecord,
        model: String) -> [Observation]
    {
        let canonicalModel = Self.canonicalModel(model)
        return self.observationsByCanonicalModel[canonicalModel]?.filter {
            guard let timestamp = $0.timestamp else { return false }
            return abs(timestamp.timeIntervalSince(record.timestamp)) <= Self.maximumTelemetryMatchDistance
        } ?? []
    }

    private func allPlausibleObservationsRepresented(
        for record: CLIProxyAPIUsageRecord,
        model: String,
        representedObservations: Set<ObservationKey>) -> Bool
    {
        let plausibleKeys = self.plausibleObservations(for: record, model: model).map(Self.observationKey)
        guard !plausibleKeys.isEmpty else { return true }
        return Set(plausibleKeys).count == plausibleKeys.count
            && plausibleKeys.allSatisfy(representedObservations.contains)
    }

    private static func observationKey(_ observation: Observation) -> ObservationKey {
        ObservationKey(
            sourceID: observation.sourceID,
            sessionID: observation.sessionID,
            canonicalModel: self.canonicalModel(observation.model),
            timestamp: observation.timestamp)
    }

    private static func indexUsageRecords(
        _ records: [CLIProxyAPIUsageRecord]) -> [String: [IndexedUsageRecord]]
    {
        var recordsByModel: [String: [IndexedUsageRecord]] = [:]
        for (sourceID, record) in records.enumerated() where !record.failed
            && record.generate
            && self.isClaudeMessagesGenerationEndpoint(record.endpoint)
        {
            let models = Set([self.canonicalModel(record.alias), self.canonicalModel(record.model)])
            for model in models where !model.isEmpty {
                recordsByModel[model, default: []].append(IndexedUsageRecord(
                    sourceID: sourceID,
                    record: record))
            }
        }
        return recordsByModel.mapValues { records in
            records.sorted { $0.record.timestamp < $1.record.timestamp }
        }
    }

    private static func firstRecordIndex(
        atOrAfter timestamp: Date,
        in records: [IndexedUsageRecord]) -> Int
    {
        var lowerBound = 0
        var upperBound = records.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if records[midpoint].record.timestamp < timestamp {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private func authInventoryUpstream(
        model: String,
        modelProvider: CostUsageAttribution.ModelProvider,
        routeObserved: Bool,
        configuredCodexModel: String?) -> CostUsageAttribution.Upstream?
    {
        let providers = Array(Set(self.authProviders))
        // Provider-specific by design: CLIProxyAPI's auth inventory names its Codex OAuth backend with a raw string.
        let codexProviders = providers.filter {
            $0.provider.caseInsensitiveCompare("codex") == .orderedSame
        }
        if let configuredCodexModel {
            guard routeObserved,
                  codexProviders.count == 1,
                  let provider = codexProviders.first
            else { return nil }
            return CostUsageAttribution.Upstream(
                provider: provider.provider,
                authType: provider.authType,
                model: configuredCodexModel)
        }

        guard routeObserved,
              modelProvider == .openAI,
              !self.observationsBySessionID.isEmpty,
              !self.hasConfiguredOpenAIAPIUpstream,
              providers.count == 1,
              let provider = providers.first,
              // Provider-specific by design: only CLIProxyAPI's Codex OAuth backend proves subscription attribution.
              provider.provider.caseInsensitiveCompare("codex") == .orderedSame
        else { return nil }
        return CostUsageAttribution.Upstream(
            provider: provider.provider,
            authType: provider.authType,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func uniqueClosest<T>(
        _ candidates: [T],
        target: Date,
        timestamp: (T) -> Date?) -> T?
    {
        let ranked = candidates.compactMap { candidate -> (candidate: T, distance: TimeInterval)? in
            guard let date = timestamp(candidate) else { return nil }
            return (candidate, abs(date.timeIntervalSince(target)))
        }
        .sorted { $0.distance < $1.distance }
        guard let first = ranked.first else {
            let undated = candidates.filter { timestamp($0) == nil }
            return undated.count == 1 ? undated[0] : nil
        }
        guard ranked.count == 1 || ranked[1].distance > first.distance else { return nil }
        return first.candidate
    }

    private static func upstream(
        _ record: CLIProxyAPIUsageRecord) -> CostUsageAttribution.Upstream
    {
        let authType: CostUsageAttribution.Upstream.AuthType = switch record.authType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "oauth": .oauth
        case "api_key", "api-key", "apikey": .apiKey
        default: .unknown
        }
        return CostUsageAttribution.Upstream(
            provider: record.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            authType: authType,
            model: record.model.trimmingCharacters(in: .whitespacesAndNewlines),
            executorType: record.executorType?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct AuthFile: Decodable {
        let type: String?
        let disabled: Bool?
    }

    private final class ObservationCache: @unchecked Sendable {
        private struct Metadata: Equatable {
            let modificationDate: Date?
            let size: Int?
        }

        private struct Entry {
            let metadata: Metadata
            let observation: Observation?
        }

        private let lock = NSLock()
        private var entriesByDirectory: [String: [String: Entry]] = [:]

        func load(
            logDirectory: URL,
            fileManager: FileManager,
            forceReload: Bool,
            checkCancellation: (() throws -> Void)?,
            parse: (URL) -> Observation?) throws -> [Observation]
        {
            try self.lock.withLock {
                let directoryKey = logDirectory.standardizedFileURL.path
                let resourceKeys: Set<URLResourceKey> = [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                ]
                guard let urls = try? fileManager.contentsOfDirectory(
                    at: logDirectory,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles])
                else {
                    self.entriesByDirectory.removeValue(forKey: directoryKey)
                    return []
                }

                let cachedEntries = forceReload ? [:] : self.entriesByDirectory[directoryKey] ?? [:]
                var currentEntries: [String: Entry] = [:]
                var observations: [Observation] = []
                for url in urls where url.pathExtension.lowercased() == "log" {
                    try checkCancellation?()
                    guard let values = try? url.resourceValues(forKeys: resourceKeys),
                          values.isRegularFile == true
                    else { continue }

                    let path = url.standardizedFileURL.path
                    let metadata = Metadata(
                        modificationDate: values.contentModificationDate,
                        size: values.fileSize)
                    let entry = if let cached = cachedEntries[path],
                                   cached.metadata == metadata
                    {
                        cached
                    } else {
                        Entry(metadata: metadata, observation: parse(url))
                    }
                    currentEntries[path] = entry
                    if let observation = entry.observation {
                        observations.append(observation)
                    }
                }

                if currentEntries.isEmpty {
                    self.entriesByDirectory.removeValue(forKey: directoryKey)
                } else {
                    self.entriesByDirectory[directoryKey] = currentEntries
                }
                return observations
            }
        }
    }

    private static func loadAuthProviders(
        home: URL,
        fileManager: FileManager) -> [AuthProvider]
    {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let decoder = JSONDecoder()
        let providers = urls.compactMap { url -> AuthProvider? in
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let auth = try? decoder.decode(AuthFile.self, from: data),
                  auth.disabled != true,
                  let rawType = auth.type?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawType.isEmpty
            else { return nil }
            // Provider-specific by design: CLIProxyAPI serializes Codex OAuth credentials under the raw type name.
            let isCodex = rawType.caseInsensitiveCompare("codex") == .orderedSame
            return AuthProvider(
                provider: isCodex ? "codex" : rawType.lowercased(),
                authType: isCodex ? .oauth : .unknown)
        }
        return Array(Set(providers))
    }

    static func parseCodexOAuthModelAliases(_ text: String) -> [String: String] {
        var aliases: [String: String] = [:]
        var rootIndent: Int?
        var codexIndent: Int?
        var currentName: String?
        var currentAlias: String?
        var currentItemIndent: Int?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let structureKey = self.simpleYAMLMappingKey(trimmed)
            let indent = line.prefix { $0 == " " }.count

            if rootIndent == nil {
                if structureKey == "oauth-model-alias" {
                    rootIndent = indent
                }
                continue
            }

            guard let rootIndent else { continue }
            if indent <= rootIndent {
                break
            }
            if codexIndent == nil {
                // Provider-specific by design: this parser reads only CLIProxyAPI's Codex OAuth alias section.
                if structureKey == "codex" {
                    codexIndent = indent
                }
                continue
            }

            guard let codexIndent else { continue }
            if indent <= codexIndent {
                break
            }

            let startsItem = trimmed == "-" || trimmed.hasPrefix("- ")
            if startsItem {
                if let currentName, let currentAlias, !currentName.isEmpty, !currentAlias.isEmpty {
                    aliases[currentAlias] = currentName
                }
                (currentName, currentAlias) = (nil, nil)
                currentItemIndent = indent
            }
            guard startsItem || currentItemIndent.map({ indent > $0 }) == true else {
                (currentName, currentAlias, currentItemIndent) = (nil, nil, nil)
                continue
            }
            let field = startsItem ? String(trimmed.dropFirst(2)) : trimmed
            if let flowMapping = self.simpleYAMLFlowMapping(field) {
                currentName = flowMapping["name"]
                currentAlias = flowMapping["alias"]
            } else if field.hasPrefix("name:") {
                currentName = self.simpleYAMLScalar(String(field.dropFirst("name:".count)))
            } else if field.hasPrefix("alias:") {
                currentAlias = self.simpleYAMLScalar(String(field.dropFirst("alias:".count)))
            }
        }
        if let currentName, let currentAlias, !currentName.isEmpty, !currentAlias.isEmpty {
            aliases[currentAlias] = currentName
        }
        return aliases
    }

    static func hasCodexOAuthModelAliasRoute(
        home: URL,
        fileManager: FileManager = .default) -> Bool
    {
        guard !self.loadCodexOAuthModelAliases(home: home, fileManager: fileManager).isEmpty else {
            return false
        }
        // Provider-specific by design: a Codex auth inventory entry is required to activate Codex model aliases.
        return self.loadAuthProviders(home: home, fileManager: fileManager).contains {
            $0.provider.caseInsensitiveCompare("codex") == .orderedSame
        }
    }

    private static func loadCodexOAuthModelAliases(
        home: URL,
        fileManager: FileManager) -> [String: String]
    {
        let url = home.appendingPathComponent("config.yaml", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        return self.parseCodexOAuthModelAliases(text)
    }

    private static func simpleYAMLScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "" }
        if first == "\"" || first == "'" {
            let remainder = trimmed.dropFirst()
            guard let end = remainder.firstIndex(of: first) else { return String(remainder) }
            return String(remainder[..<end])
        }
        return trimmed.split(separator: "#", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func hasConfiguredOpenAIAPIUpstream(
        home: URL,
        fileManager: FileManager) -> Bool
    {
        let url = home.appendingPathComponent("config.yaml", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        let conflictingKeys = ["codex-api-key", "openai-compatibility"]
        return conflictingKeys.contains { self.topLevelYAMLSequenceHasEntries($0, in: text) }
    }

    private static func loadObservations(
        logDirectory: URL,
        fileManager: FileManager,
        forceReload: Bool,
        checkCancellation: (() throws -> Void)?) throws -> [Observation]
    {
        try self.observationCache.load(
            logDirectory: logDirectory,
            fileManager: fileManager,
            forceReload: forceReload,
            checkCancellation: checkCancellation)
        { url in
            self.parseObservation(url: url)
        }
    }

    private static func parseObservation(url: URL) -> Observation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: self.maxLogPrefixBytes),
              let text = String(data: data, encoding: .utf8),
              let bodyMarkerRange = text.range(of: self.requestBodyMarker)
        else { return nil }

        let info = String(text[..<bodyMarkerRange.lowerBound])
        guard let requestURL = self.field("URL", in: info),
              self.isClaudeMessagesGenerationEndpoint(requestURL),
              let sessionID = self.field("X-Claude-Code-Session-Id", in: info)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty
        else { return nil }

        let bodyStart = bodyMarkerRange.upperBound
        let bodyEnd = self.responseMarkers.compactMap {
            text.range(of: $0, range: bodyStart..<text.endIndex)?.lowerBound
        }.min() ?? text.endIndex
        let requestBody = String(text[bodyStart..<bodyEnd])
        guard let model = self.topLevelJSONStringValue(forKey: "model", in: requestBody) else { return nil }
        let timestamp = self.field("Timestamp", in: info).flatMap(CostUsageDateParser.parse)
        return Observation(
            sourceID: url.standardizedFileURL.path,
            sessionID: sessionID,
            model: model,
            timestamp: timestamp)
    }

    static func isClaudeMessagesGenerationEndpoint(_ value: String) -> Bool {
        let candidate = value.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? value
        guard let components = URLComponents(string: candidate) else { return false }
        return components.path == "/v1/messages"
    }

    private static func field(_ name: String, in text: String) -> String? {
        let prefix = "\(name):"
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(prefix) else { continue }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func topLevelJSONStringValue(forKey key: String, in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String
        else {
            let escapedKey = NSRegularExpression.escapedPattern(for: key)
            guard let regex = try? NSRegularExpression(
                pattern: "\"\(escapedKey)\"\\s*:\\s*\"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""),
                let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)),
                let valueRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[valueRange])
        }
        return value
    }

    private static func canonicalModel(_ raw: String) -> String {
        let codexNormalized = CostUsagePricing.normalizeCodexModel(raw)
        return CostUsagePricing.normalizeClaudeModel(codexNormalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

extension CLIProxyAPIAttributionResolver {
    private static func simpleYAMLMappingKey(_ raw: String) -> String? {
        guard let separator = self.firstUnquotedColon(in: raw) else { return nil }
        let key = self.simpleYAMLScalar(String(raw[..<separator]))
        return key.isEmpty ? nil : key
    }

    private static func simpleYAMLFlowMapping(_ raw: String) -> [String: String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "{" else { return nil }

        var fields: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var reachedEnd = false
        for character in trimmed.dropFirst() {
            if let activeQuote = quote {
                current.append(character)
                if activeQuote == "\"", character == "\\", !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote, !escaped {
                    quote = nil
                }
                escaped = false
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                fields.append(current)
                current = ""
            } else if character == "}" {
                fields.append(current)
                reachedEnd = true
                break
            } else {
                current.append(character)
            }
        }
        guard reachedEnd, quote == nil else { return nil }

        var mapping: [String: String] = [:]
        for field in fields {
            guard let separator = self.firstUnquotedColon(in: field) else { continue }
            let key = self.simpleYAMLScalar(String(field[..<separator]))
            let value = self.simpleYAMLScalar(String(field[field.index(after: separator)...]))
            guard !key.isEmpty, !value.isEmpty else { continue }
            mapping[key] = value
        }
        return mapping
    }

    private static func firstUnquotedColon(in value: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if let activeQuote = quote {
                if activeQuote == "\"", character == "\\", !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote, !escaped {
                    quote = nil
                }
                escaped = false
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ":" {
                return index
            }
        }
        return nil
    }

    private static func topLevelYAMLSequenceHasEntries(_ key: String, in text: String) -> Bool {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() {
            guard line.first?.isWhitespace != true else { continue }
            let structure = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.simpleYAMLMappingKey(structure) == key,
                  let separator = self.firstUnquotedColon(in: structure)
            else { continue }

            let inlineValue = self.simpleYAMLScalar(String(structure[structure.index(after: separator)...]))
            if !inlineValue.isEmpty {
                let compactValue = inlineValue.filter { !$0.isWhitespace }
                return compactValue != "[]" && compactValue != "null" && compactValue != "~"
            }

            for nestedLine in lines.dropFirst(index + 1) {
                let nested = nestedLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nested.isEmpty, !nested.hasPrefix("#") else { continue }
                guard nestedLine.first?.isWhitespace == true else { return false }
                if self.simpleYAMLScalar(nested).hasPrefix("-") {
                    return true
                }
            }
            return false
        }
        return false
    }

    private func closestUsageRecordMatch(
        observation: Observation,
        model: String,
        tokens: TokenSignature?) -> UsageRecordMatch?
    {
        guard let observationTimestamp = observation.timestamp else { return nil }
        let candidates = self.usageRecordMatches(
            observation: observation,
            model: model,
            tokens: tokens)
        return Self.uniqueClosest(
            candidates,
            target: observationTimestamp,
            timestamp: { $0.record.timestamp })
    }

    private func closestUsageRecordMatch(request: Request) -> UsageRecordMatch? {
        guard let timestamp = Self.timestamp(for: request), let tokens = request.tokens else { return nil }
        let candidates = self.usageRecordMatches(
            model: request.model,
            timestamp: timestamp,
            tokens: tokens,
            maximumDistance: Self.maximumTelemetryOnlyMatchDistance)
        return Self.uniqueClosest(
            candidates,
            target: timestamp,
            timestamp: { $0.record.timestamp })
    }

    private func usageRecordMatches(
        observation: Observation,
        model: String,
        tokens: TokenSignature?) -> [UsageRecordMatch]
    {
        guard let observationTimestamp = observation.timestamp else { return [] }
        return self.usageRecordMatches(
            model: model,
            timestamp: observationTimestamp,
            tokens: tokens,
            maximumDistance: Self.maximumTelemetryMatchDistance)
    }

    private func usageRecordMatches(
        model: String,
        timestamp: Date,
        tokens: TokenSignature?,
        maximumDistance: TimeInterval) -> [UsageRecordMatch]
    {
        let canonicalModel = Self.canonicalModel(model)
        guard let records = self.usageRecordsByCanonicalModel[canonicalModel] else { return [] }
        let earliest = timestamp.addingTimeInterval(-maximumDistance)
        let latest = timestamp.addingTimeInterval(maximumDistance)
        let startIndex = Self.firstRecordIndex(atOrAfter: earliest, in: records)
        var candidates: [UsageRecordMatch] = []
        for index in startIndex..<records.endIndex {
            let indexedRecord = records[index]
            let record = indexedRecord.record
            guard record.timestamp <= latest else { break }
            if tokens.map({ Self.tokensMatch($0, record.tokens) }) ?? true {
                candidates.append(UsageRecordMatch(
                    key: UsageRecordKey(sourceID: indexedRecord.sourceID),
                    record: record))
            }
        }
        return candidates
    }

    private static func tokensMatch(
        _ tokens: TokenSignature,
        _ telemetry: CLIProxyAPIUsageRecord.Tokens) -> Bool
    {
        guard telemetry.output == tokens.output else { return false }
        let (inputAndCacheRead, inputAndCacheReadOverflow) = tokens.input.addingReportingOverflow(tokens.cacheRead)
        guard !inputAndCacheReadOverflow else { return false }
        let (claudeInputTotal, claudeInputTotalOverflow) = inputAndCacheRead.addingReportingOverflow(tokens.cacheCreate)
        guard !claudeInputTotalOverflow else { return false }
        if telemetry.cacheRead != 0 || telemetry.cacheCreation != 0 {
            return telemetry.cacheRead == tokens.cacheRead
                && telemetry.cacheCreation == tokens.cacheCreate
                && (telemetry.input == tokens.input || telemetry.input == claudeInputTotal)
        }
        let (telemetryInputTotal, telemetryInputTotalOverflow) = telemetry.input
            .addingReportingOverflow(telemetry.cached)
        return telemetry.input == tokens.input
            || telemetry.input == claudeInputTotal
            || (!telemetryInputTotalOverflow && telemetryInputTotal == claudeInputTotal)
    }

    static func inputArtifactFingerprint(
        home: URL,
        fileManager: FileManager = .default,
        checkCancellation: (() throws -> Void)? = nil) throws -> [String: CostUsageClaudeFileStamp]
    {
        var urls = [home.appendingPathComponent("config.yaml", isDirectory: false)]
        if let authURLs = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            urls.append(contentsOf: authURLs.filter { $0.pathExtension.lowercased() == "json" })
        }
        let logDirectory = home.appendingPathComponent("logs", isDirectory: true)
        if let logURLs = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            urls.append(contentsOf: logURLs.filter { $0.pathExtension.lowercased() == "log" })
        }

        var fingerprint: [String: CostUsageClaudeFileStamp] = [:]
        for url in urls {
            try checkCancellation?()
            guard let stamp = CostUsageClaudeFileStamp.read(at: url) else { continue }
            fingerprint[url.standardizedFileURL.path] = stamp
        }
        return fingerprint
    }
}
