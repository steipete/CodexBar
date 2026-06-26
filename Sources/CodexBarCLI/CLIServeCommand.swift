import CodexBarCore
import Commander
import Foundation

struct ServeOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("port"), help: "Local HTTP port (default: 8080)")
    var port: Int?

    @Option(name: .long("refresh-interval"), help: "Response cache TTL in seconds (default: 60)")
    var refreshInterval: Double?

    @Option(
        name: .long("request-timeout"),
        help: "Total per-request deadline in seconds; 0 disables (default: 30)")
    var requestTimeout: Double?
}

enum CLIServeRoute: Equatable {
    case health
    case usage(provider: String?)
    case cost(provider: String?)
}

enum CLIServeRouteError: Error, Equatable {
    case methodNotAllowed
    case notFound
}

enum CLIServeRouter {
    static func route(method: String, path: String, queryItems: [String: String]) throws -> CLIServeRoute {
        guard method.uppercased() == "GET" else {
            throw CLIServeRouteError.methodNotAllowed
        }

        let provider = queryItems["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = provider?.isEmpty == false ? provider : nil

        switch path {
        case "/health":
            return .health
        case "/usage":
            return .usage(provider: normalizedProvider)
        case "/cost":
            return .cost(provider: normalizedProvider)
        default:
            throw CLIServeRouteError.notFound
        }
    }
}

private struct ServeErrorPayload: Encodable {
    let error: String
}

private struct ServeHealthPayload: Encodable {
    let status: String
    let version: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case version
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.version, forKey: .version)
    }
}

struct CLIServeConfigSnapshot {
    let config: CodexBarConfig
    let cacheToken: String
}

private struct ServeRuntime {
    let configStore: CodexBarConfigStore
    let cache: CLIServeResponseCache
    let refreshInterval: TimeInterval
    let requestTimeout: TimeInterval
    let healthVersion: String?
}

private final class CLIServeDeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CLILocalHTTPResponse, Never>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<CLILocalHTTPResponse, Never>) {
        self.continuation = continuation
    }

    func setWorkTask(_ task: Task<Void, Never>) {
        var shouldCancel = false
        self.lock.lock()
        if self.continuation == nil {
            shouldCancel = true
        } else {
            self.workTask = task
        }
        self.lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        var shouldCancel = false
        self.lock.lock()
        if self.continuation == nil {
            shouldCancel = true
        } else {
            self.timeoutTask = task
        }
        self.lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func finish(_ response: CLILocalHTTPResponse, cancelWork: Bool, cancelTimeout: Bool) {
        let continuation: CheckedContinuation<CLILocalHTTPResponse, Never>?
        let workTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        self.lock.lock()
        continuation = self.continuation
        self.continuation = nil
        workTask = cancelWork ? self.workTask : nil
        timeoutTask = cancelTimeout ? self.timeoutTask : nil
        self.workTask = nil
        self.timeoutTask = nil
        self.lock.unlock()

        workTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: response)
    }
}

enum CLIServeCacheLookup {
    case response(CLILocalHTTPResponse)
    case miss
}

actor CLIServeResponseCache {
    static let maximumStaleTTL: TimeInterval = 3600

    private struct Entry {
        let expiresAt: Date
        let response: CLILocalHTTPResponse
    }

    struct CachePolicy {
        /// How long a successful response stays fresh.
        let ttl: TimeInterval
        /// How long a last-good response may stand in for a failed refresh.
        let staleTTL: TimeInterval
    }

    private struct LastGoodEntry {
        let recordedAt: Date
        let response: CLILocalHTTPResponse
    }

    private struct UsageItemKey: Hashable {
        let provider: String
        let accountID: String
    }

    private struct LastGoodUsageItem {
        let recordedAt: Date
        let data: Data
    }

    private struct UsageMergeResult {
        let response: CLILocalHTTPResponse
    }

    private var entries: [String: Entry] = [:]
    private var lastGood: [String: LastGoodEntry] = [:]
    private var lastGoodUsageItems: [String: [UsageItemKey: LastGoodUsageItem]] = [:]
    private var inFlightKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<CLIServeCacheLookup, Never>]] = [:]

    private func pruneExpiredEntries(now: Date) {
        self.entries = self.entries.filter { $0.value.expiresAt > now }
        self.lastGood = self.lastGood.filter {
            now.timeIntervalSince($0.value.recordedAt) <= Self.maximumStaleTTL
        }
        self.lastGoodUsageItems = self.lastGoodUsageItems.compactMapValues { items in
            let retained = items.filter {
                now.timeIntervalSince($0.value.recordedAt) <= Self.maximumStaleTTL
            }
            return retained.isEmpty ? nil : retained
        }
    }

    private func response(for key: String) -> CLILocalHTTPResponse? {
        guard let entry = self.entries[key] else { return nil }
        return entry.response
    }

    func responseOrStartFetch(for key: String, now: Date) async -> CLIServeCacheLookup {
        self.pruneExpiredEntries(now: now)
        if let cached = self.response(for: key) {
            return .response(cached)
        }

        if self.inFlightKeys.contains(key) {
            return await withCheckedContinuation { continuation in
                self.waiters[key, default: []].append(continuation)
            }
        }

        self.inFlightKeys.insert(key)
        return .miss
    }

    /// Completes an in-flight fetch and returns the response delivered to
    /// waiters. Successful responses are cached normally. Failed non-usage
    /// fetches may use a whole-response fallback within `staleTTL`; usage
    /// responses only replace keyed error rows from the same identified account.
    func completeFetch(
        _ response: CLILocalHTTPResponse,
        for key: String,
        policy: CachePolicy,
        now: Date,
        shouldCache: Bool) -> CLILocalHTTPResponse
    {
        let delivered: CLILocalHTTPResponse
        let staleResponse = self.staleResponse(for: key, staleTTL: policy.staleTTL, now: now)
        let usageMerge = self.mergeLastGoodUsageItems(
            into: response,
            for: key,
            staleTTL: policy.staleTTL,
            now: now,
            replaceCachedItems: shouldCache)
        if shouldCache {
            self.store(response, for: key, ttl: policy.ttl, now: now)
            if key.hasPrefix("usage:") {
                self.lastGood[key] = nil
            } else {
                self.lastGood[key] = LastGoodEntry(recordedAt: now, response: response)
            }
            delivered = response
        } else if let usageMerge {
            delivered = usageMerge.response
            self.lastGood[key] = nil
        } else {
            delivered = staleResponse ?? response
        }
        self.inFlightKeys.remove(key)
        let waiters = self.waiters.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume(returning: .response(delivered))
        }
        return delivered
    }

    private func staleResponse(
        for key: String,
        staleTTL: TimeInterval,
        now: Date) -> CLILocalHTTPResponse?
    {
        guard staleTTL > 0 else { return nil }
        // A timeout cannot prove which usage account is currently active.
        if key.hasPrefix("usage:") {
            return nil
        }
        if let entry = self.lastGood[key],
           now.timeIntervalSince(entry.recordedAt) <= staleTTL
        {
            return entry.response
        }
        if self.lastGood[key] != nil {
            self.lastGood[key] = nil
        }
        return nil
    }

    private func mergeLastGoodUsageItems(
        into response: CLILocalHTTPResponse,
        for key: String,
        staleTTL: TimeInterval,
        now: Date,
        replaceCachedItems: Bool) -> UsageMergeResult?
    {
        guard key.hasPrefix("usage:"),
              response.status == .ok,
              staleTTL > 0,
              var items = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        else {
            return nil
        }

        var cachedItems = replaceCachedItems ? [:] : self.lastGoodUsageItems[key] ?? [:]
        if !replaceCachedItems {
            cachedItems = cachedItems.filter { now.timeIntervalSince($0.value.recordedAt) <= staleTTL }
        }
        let itemKeys = items.indices.compactMap { index in
            Self.usageItemKey(
                items[index],
                accountID: Self.cacheAccountKey(at: index, in: response.usageCacheKeys))
        }
        let duplicateKeys = Set(
            Dictionary(grouping: itemKeys, by: { $0 })
                .filter { $0.value.count > 1 }
                .map(\.key))
        for duplicateKey in duplicateKeys {
            cachedItems[duplicateKey] = nil
        }
        var replacedError = false

        for index in items.indices {
            let item = items[index]
            guard let itemKey = Self.usageItemKey(
                item,
                accountID: Self.cacheAccountKey(at: index, in: response.usageCacheKeys))
            else {
                continue
            }
            guard !duplicateKeys.contains(itemKey) else {
                continue
            }

            if Self.hasError(item) {
                if let cached = cachedItems[itemKey],
                   let cachedItem = try? JSONSerialization.jsonObject(with: cached.data) as? [String: Any]
                {
                    items[index] = cachedItem
                    replacedError = true
                }
            } else {
                if let data = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) {
                    cachedItems[itemKey] = LastGoodUsageItem(recordedAt: now, data: data)
                }
            }
        }
        self.lastGoodUsageItems[key] = cachedItems

        guard replacedError,
              let body = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        else {
            return UsageMergeResult(response: response)
        }
        return UsageMergeResult(
            response: CLILocalHTTPResponse(
                status: response.status,
                body: body,
                contentType: response.contentType,
                usageCacheKeys: response.usageCacheKeys))
    }

    private static func usageItemKey(_ item: [String: Any], accountID: String?) -> UsageItemKey? {
        guard let provider = item["provider"] as? String,
              !provider.isEmpty,
              let accountID,
              !accountID.isEmpty
        else {
            return nil
        }
        return UsageItemKey(provider: provider, accountID: accountID)
    }

    private static func cacheAccountKey(at index: Int, in keys: [String?]?) -> String? {
        guard let keys, keys.indices.contains(index) else { return nil }
        return keys[index]
    }

    private static func hasError(_ item: [String: Any]) -> Bool {
        guard let error = item["error"] else { return false }
        return !(error is NSNull)
    }

    private func store(_ response: CLILocalHTTPResponse, for key: String, ttl: TimeInterval, now: Date) {
        guard ttl > 0, response.status == .ok else { return }
        self.entries[key] = Entry(expiresAt: now.addingTimeInterval(ttl), response: response)
    }

    func cachedEntryCount() -> Int {
        self.entries.count
    }

    func cachedStaleVariantCount() -> Int {
        self.lastGood.count + self.lastGoodUsageItems.count
    }
}

private enum CLIServeArgumentError: LocalizedError {
    case invalidPort
    case invalidRefreshInterval
    case invalidRequestTimeout
    case invalidProvider(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "--port must be between 1 and 65535."
        case .invalidRefreshInterval:
            "--refresh-interval must be zero or greater."
        case .invalidRequestTimeout:
            "--request-timeout must be zero or greater."
        case let .invalidProvider(provider):
            "Unknown provider '\(provider)'."
        }
    }
}

extension CodexBarCLI {
    static let defaultServeRequestTimeout: TimeInterval = 30

    static func runServe(_ values: ParsedValues) async {
        let output = CLIOutputPreferences(format: .json, jsonOnly: true, pretty: false)
        let port = Self.decodeServePort(from: values)
        let refreshInterval = Self.decodeServeRefreshInterval(from: values)
        let requestTimeout = Self.decodeServeRequestTimeout(from: values)

        guard let port else {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.invalidPort.localizedDescription,
                output: output,
                kind: .args)
        }

        guard let refreshInterval else {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.invalidRefreshInterval.localizedDescription,
                output: output,
                kind: .args)
        }

        guard let requestTimeout else {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.invalidRequestTimeout.localizedDescription,
                output: output,
                kind: .args)
        }

        // Resolve the running build version once, at startup, before an in-place
        // app/tarball update can replace the on-disk binary. Resolving it lazily
        // per request would let a stale serve report the newly installed version
        // and defeat the client stale-process detection this field exists for.
        let runtime = ServeRuntime(
            configStore: CodexBarConfigStore(),
            cache: CLIServeResponseCache(),
            refreshInterval: refreshInterval,
            requestTimeout: requestTimeout,
            healthVersion: Self.currentVersion())
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: port) { request in
            await Self.handleServeRequest(request, runtime: runtime)
        }
        let signalMonitor = CLITerminationSignalMonitor { _ in
            TTYCommandRunner.terminateActiveProcessesForAppShutdown()
            server.stop()
        }
        defer { signalMonitor.cancel() }

        do {
            try await server.run {
                Self.writeStderr("CodexBar server listening on http://127.0.0.1:\(port)\n")
            }
        } catch {
            await Self.shutdownServeSessions()
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
        await Self.shutdownServeSessions()
    }

    private static func shutdownServeSessions() async {
        await ProviderCLISessionLifecycle.shutdownPersistentSessions()
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
    }

    static func decodeServePort(from values: ParsedValues) -> UInt16? {
        let raw = values.options["port"]?.last
        let parsed: Int
        if let raw {
            guard let value = Int(raw) else { return nil }
            parsed = value
        } else {
            parsed = 8080
        }
        guard parsed > 0, parsed <= Int(UInt16.max) else { return nil }
        return UInt16(parsed)
    }

    static func decodeServeRefreshInterval(from values: ParsedValues) -> TimeInterval? {
        let raw = values.options["refreshInterval"]?.last
        let parsed: Double
        if let raw {
            guard let value = Double(raw) else { return nil }
            parsed = value
        } else {
            parsed = 60
        }
        guard parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    static func decodeServeRequestTimeout(from values: ParsedValues) -> TimeInterval? {
        let raw = values.options["requestTimeout"]?.last
        let parsed: Double
        if let raw {
            guard let value = Double(raw) else { return nil }
            parsed = value
        } else {
            parsed = Self.defaultServeRequestTimeout
        }
        guard parsed >= 0 else { return nil }
        return parsed
    }

    private static func handleServeRequest(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime) async -> CLILocalHTTPResponse
    {
        let route: CLIServeRoute
        do {
            route = try CLIServeRouter.route(
                method: request.method,
                path: request.path,
                queryItems: request.queryItems)
        } catch CLIServeRouteError.methodNotAllowed {
            return Self.serveError(status: .methodNotAllowed, message: "method not allowed")
        } catch {
            return Self.serveError(status: .notFound, message: "not found")
        }

        switch route {
        case .health:
            return Self.serveHealthResponse(version: runtime.healthVersion)
        case let .usage(provider):
            let snapshot: CLIServeConfigSnapshot
            do {
                snapshot = try Self.loadServeConfigSnapshot(configStore: runtime.configStore)
            } catch {
                return Self.serveError(status: .internalServerError, message: error.localizedDescription)
            }
            return await Self.cachedServeResponse(
                key: Self.serveCacheKey(kind: "usage", provider: provider, configToken: snapshot.cacheToken),
                cache: runtime.cache,
                refreshInterval: runtime.refreshInterval,
                requestTimeout: runtime.requestTimeout)
            {
                await Self.serveUsage(
                    provider: provider,
                    config: snapshot.config,
                    refreshInterval: runtime.refreshInterval)
            }
        case let .cost(provider):
            let snapshot: CLIServeConfigSnapshot
            do {
                snapshot = try Self.loadServeConfigSnapshot(configStore: runtime.configStore)
            } catch {
                return Self.serveError(status: .internalServerError, message: error.localizedDescription)
            }
            return await Self.cachedServeResponse(
                key: Self.serveCacheKey(kind: "cost", provider: provider, configToken: snapshot.cacheToken),
                cache: runtime.cache,
                refreshInterval: runtime.refreshInterval,
                requestTimeout: runtime.requestTimeout)
            {
                await Self.serveCost(provider: provider, config: snapshot.config)
            }
        }
    }

    static func loadServeConfigSnapshot(
        configStore: CodexBarConfigStore = CodexBarConfigStore()) throws -> CLIServeConfigSnapshot
    {
        let config = try configStore.load() ?? CodexBarConfig.makeDefault()
        return try CLIServeConfigSnapshot(
            config: config,
            cacheToken: Self.serveConfigCacheToken(for: config))
    }

    static func serveCacheKey(kind: String, provider: String?, configToken: String) -> String {
        "\(kind):\(provider ?? ""):\(configToken)"
    }

    static func serveConfigCacheToken(for config: CodexBarConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config.normalized())
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func cachedServeResponse(
        key: String,
        cache: CLIServeResponseCache,
        refreshInterval: TimeInterval,
        requestTimeout: TimeInterval = CodexBarCLI.defaultServeRequestTimeout,
        makeResponse: @Sendable @escaping () async -> CLILocalHTTPResponse) async -> CLILocalHTTPResponse
    {
        switch await cache.responseOrStartFetch(for: key, now: Date()) {
        case let .response(response):
            return response
        case .miss:
            let response = await Self.serveResponseWithDeadline(seconds: requestTimeout) {
                await makeResponse()
            }
            return await cache.completeFetch(
                response,
                for: key,
                policy: CLIServeResponseCache.CachePolicy(
                    ttl: refreshInterval,
                    staleTTL: Self.serveStaleTTL(refreshInterval: refreshInterval)),
                now: Date(),
                shouldCache: Self.shouldCacheServeResponse(response))
        }
    }

    private static func serveResponseWithDeadline(
        seconds timeout: TimeInterval,
        makeResponse: @Sendable @escaping () async -> CLILocalHTTPResponse) async -> CLILocalHTTPResponse
    {
        let clampedTimeout = min(max(timeout, 0), 86400)
        guard clampedTimeout > 0 else {
            return await makeResponse()
        }
        let nanoseconds = max(1, UInt64((clampedTimeout * 1_000_000_000).rounded(.up)))

        return await withCheckedContinuation { continuation in
            let state = CLIServeDeadlineState(continuation: continuation)
            let workTask = Task {
                let response = await makeResponse()
                state.finish(response, cancelWork: false, cancelTimeout: true)
            }
            state.setWorkTask(workTask)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                state.finish(
                    Self.serveError(status: .gatewayTimeout, message: "request timed out"),
                    cancelWork: true,
                    cancelTimeout: false)
            }
            state.setTimeoutTask(timeoutTask)
        }
    }

    /// How long a last-good response may be served in place of a failed
    /// refresh. Ten refresh intervals, with a five-minute floor and one-hour
    /// ceiling. Zero (stale fallback disabled) when response caching is disabled.
    static func serveStaleTTL(refreshInterval: TimeInterval) -> TimeInterval {
        guard refreshInterval > 0 else { return 0 }
        guard refreshInterval.isFinite else { return CLIServeResponseCache.maximumStaleTTL }
        return min(max(refreshInterval * 10, 300), CLIServeResponseCache.maximumStaleTTL)
    }

    static func serveCLISessionIdleWindow(refreshInterval: TimeInterval) -> TimeInterval {
        max(180, refreshInterval + 60)
    }

    static func shouldCacheServeResponse(_ response: CLILocalHTTPResponse) -> Bool {
        guard response.status == .ok else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return true
        }
        return !payload.contains { item in
            guard let error = item["error"] else { return false }
            return !(error is NSNull)
        }
    }

    private static func serveUsage(
        provider rawProvider: String?,
        config: CodexBarConfig,
        refreshInterval: TimeInterval) async -> CLILocalHTTPResponse
    {
        let selection: ProviderSelection
        do {
            selection = try Self.serveProviderSelection(rawProvider: rawProvider, config: config)
        } catch {
            return Self.serveError(status: .badRequest, message: error.localizedDescription)
        }

        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: config,
                verbose: false)
        } catch {
            return Self.serveError(status: .internalServerError, message: error.localizedDescription)
        }

        let browserDetection = BrowserDetection()
        let command = UsageCommandContext(
            format: .json,
            includeCredits: true,
            sourceModeOverride: nil,
            antigravityPlanDebug: false,
            augmentDebug: false,
            webDebugDumpHTML: false,
            webTimeout: 60,
            verbose: false,
            useColor: false,
            resetStyle: Self.resetTimeDisplayStyleFromDefaults(),
            weeklyWorkDays: Self.weeklyProgressWorkDaysFromDefaults(),
            jsonOnly: true,
            includeAllCodexAccounts: true,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            persistCLISessions: true,
            persistentCLISessionIdleWindow: Self.serveCLISessionIdleWindow(refreshInterval: refreshInterval))

        var output = UsageCommandOutput()
        for provider in selection.asList {
            let providerOutput = await ProviderInteractionContext.$current.withValue(.background) {
                await Self.fetchUsageOutputs(
                    provider: provider,
                    status: nil,
                    tokenContext: tokenContext,
                    command: command)
            }
            output.merge(providerOutput)
        }

        return Self.serveJSON(
            output.payload,
            usageCacheKeys: output.payload.map(\.cacheAccountKey))
    }

    private static func serveCost(provider rawProvider: String?, config: CodexBarConfig) async -> CLILocalHTTPResponse {
        let selection: ProviderSelection
        do {
            selection = try Self.serveProviderSelection(rawProvider: rawProvider, config: config)
        } catch {
            return Self.serveError(status: .badRequest, message: error.localizedDescription)
        }

        let providers = Self.costProviders(from: selection)
        guard !providers.isEmpty else {
            return Self.serveError(status: .badRequest, message: "cost is only supported for Claude and Codex")
        }

        let fetcher = CostUsageFetcher()
        var payload: [CostPayload] = []
        for provider in providers {
            do {
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    forceRefresh: false)
                payload.append(Self.makeCostPayload(provider: provider, snapshot: snapshot, error: nil))
            } catch {
                payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
            }
        }

        return Self.serveJSON(payload)
    }

    private static func serveProviderSelection(
        rawProvider: String?,
        config: CodexBarConfig) throws -> ProviderSelection
    {
        guard let rawProvider, !rawProvider.isEmpty else {
            return providerSelection(rawOverride: nil, enabled: config.enabledProviders())
        }
        guard let selection = ProviderSelection(argument: rawProvider) else {
            throw CLIServeArgumentError.invalidProvider(rawProvider)
        }
        return selection
    }

    static func serveHealthResponse(version: String?) -> CLILocalHTTPResponse {
        self.serveJSON(ServeHealthPayload(status: "ok", version: version))
    }

    private static func serveJSON(
        _ payload: some Encodable,
        status: CLIHTTPStatus = .ok,
        usageCacheKeys: [String?]? = nil) -> CLILocalHTTPResponse
    {
        let json = Self.encodeJSON(payload, pretty: false) ?? "{}"
        return CLILocalHTTPResponse(
            status: status,
            body: Data(json.utf8),
            usageCacheKeys: usageCacheKeys)
    }

    private static func serveError(status: CLIHTTPStatus, message: String) -> CLILocalHTTPResponse {
        self.serveJSON(ServeErrorPayload(error: message), status: status)
    }
}
