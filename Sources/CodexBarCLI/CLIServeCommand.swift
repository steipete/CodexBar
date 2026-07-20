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

    @Option(name: .long("host"), help: "IPv4 bind address or localhost (default: 127.0.0.1)")
    var host: String?

    @Option(name: .long("refresh-interval"), help: "Response cache TTL in seconds (default: 60)")
    var refreshInterval: Double?

    @Option(
        name: .long("request-timeout"),
        help: "Total per-request deadline in seconds; 0 disables (default: 30)")
    var requestTimeout: Double?

    @Option(
        name: .long("dashboard-token"),
        help: "Bearer token for /dashboard/v1/snapshot (prefer CODEXBAR_DASHBOARD_TOKEN)")
    var dashboardBearer: String?

    @Flag(
        name: .long("allow-plain-http"),
        help: "Accept sending the dashboard token over cleartext HTTP on a non-loopback host")
    var allowPlainHTTP: Bool = false
}

enum CLIServeRoute: Equatable {
    case health
    case usage(provider: String?)
    case cost(provider: String?)
    case dashboardSnapshot
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
        case "/dashboard/v1/snapshot":
            return .dashboardSnapshot
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

struct ServeRuntime {
    let configStore: CodexBarConfigStore
    let cache: CLIServeResponseCache
    let providerOperations: CLIServeOperationCoordinator<UsageCommandOutput>
    let costOperations: CLIServeOperationCoordinator<CostPayload>
    let refreshInterval: TimeInterval
    let requestTimeout: TimeInterval
    let healthVersion: String?
    let dashboardAuth: CLIServeDashboardAuth
    /// True for non-loopback binds: every data route (`/usage`, `/cost`,
    /// `/dashboard/v1/snapshot`) then requires the bearer token, so account data
    /// is never exposed to the network unauthenticated. `/health` stays open.
    /// Resolved once at startup from the bind host.
    let dataRoutesRequireAuth: Bool

    init(
        configStore: CodexBarConfigStore,
        cache: CLIServeResponseCache,
        providerOperations: CLIServeOperationCoordinator<UsageCommandOutput>,
        costOperations: CLIServeOperationCoordinator<CostPayload>,
        refreshInterval: TimeInterval,
        requestTimeout: TimeInterval,
        healthVersion: String?,
        dashboardAuth: CLIServeDashboardAuth,
        bindHost: String)
    {
        self.configStore = configStore
        self.cache = cache
        self.providerOperations = providerOperations
        self.costOperations = costOperations
        self.refreshInterval = refreshInterval
        self.requestTimeout = requestTimeout
        self.healthVersion = healthVersion
        self.dashboardAuth = dashboardAuth
        self.dataRoutesRequireAuth = !CLIServeSecurity.isLoopbackHost(bindHost)
    }
}

private struct ServeResponseRequest: Sendable {
    let key: String
    let configFingerprint: String
    let refreshInterval: TimeInterval
    let deadline: ContinuousClock.Instant?
}

struct CLIServeCoordinatedResponse: Sendable {
    let response: CLILocalHTTPResponse
    let isCommitted: Bool
}

private struct ServeUsageContext: Sendable {
    let config: CodexBarConfig
    let configFingerprint: String
    let refreshInterval: TimeInterval
    let providerTimeout: TimeInterval?
    let providerDeadline: ContinuousClock.Instant?
    let providerOperations: CLIServeOperationCoordinator<UsageCommandOutput>
    let includeAllCodexAccounts: Bool

    init(
        config: CodexBarConfig,
        configFingerprint: String,
        refreshInterval: TimeInterval,
        providerTimeout: TimeInterval?,
        providerDeadline: ContinuousClock.Instant?,
        providerOperations: CLIServeOperationCoordinator<UsageCommandOutput>,
        includeAllCodexAccounts: Bool = true)
    {
        self.config = config
        self.configFingerprint = configFingerprint
        self.refreshInterval = refreshInterval
        self.providerTimeout = providerTimeout
        self.providerDeadline = providerDeadline
        self.providerOperations = providerOperations
        self.includeAllCodexAccounts = includeAllCodexAccounts
    }
}

private struct ServeDashboardContext: Sendable {
    let config: CodexBarConfig
    let usage: ServeUsageContext
    let costCollection: ServeCostCollectionContext
    let codexBarVersion: String?
}

private struct ServeCostContext: Sendable {
    let config: CodexBarConfig
    let collection: ServeCostCollectionContext
}

struct ServeCostCollectionContext: Sendable {
    let configFingerprint: String
    let providerTimeout: TimeInterval?
    let requestDeadline: ContinuousClock.Instant?
    let now: @Sendable () -> ContinuousClock.Instant
    let providerOperations: CLIServeOperationCoordinator<CostPayload>
}

actor CLIServeResponseCache {
    static let maximumStaleTTL: TimeInterval = 3600
    nonisolated let operations: CLIServeOperationCoordinator<CLIServeCoordinatedResponse>

    init(operations: CLIServeOperationCoordinator<CLIServeCoordinatedResponse> = CLIServeOperationCoordinator()) {
        self.operations = operations
    }

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

    private struct LastGoodCostItem {
        let recordedAt: Date
        let data: Data
    }

    private struct CostMergeResult {
        let response: CLILocalHTTPResponse
    }

    private var entries: [String: Entry] = [:]
    private var lastGood: [String: LastGoodEntry] = [:]
    private var lastGoodUsageItems: [String: [UsageItemKey: LastGoodUsageItem]] = [:]
    private var lastGoodCostItems: [String: [String: LastGoodCostItem]] = [:]
    private var lastGoodCostOrder: [String: [String]] = [:]

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
        self.lastGoodCostItems = self.lastGoodCostItems.compactMapValues { items in
            let retained = items.filter {
                now.timeIntervalSince($0.value.recordedAt) <= Self.maximumStaleTTL
            }
            return retained.isEmpty ? nil : retained
        }
        self.lastGoodCostOrder = self.lastGoodCostOrder.filter { self.lastGoodCostItems[$0.key] != nil }
    }

    private func response(for key: String) -> CLILocalHTTPResponse? {
        guard let entry = self.entries[key] else { return nil }
        return entry.response
    }

    func cachedResponse(for key: String, now: Date) -> CLILocalHTTPResponse? {
        self.pruneExpiredEntries(now: now)
        return self.response(for: key)
    }

    /// Transforms a fetched response through the cache's stale policy. Successful
    /// responses are cached normally. Failed non-usage
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
        let costMerge = self.mergeLastGoodCostItems(
            into: response,
            for: key,
            staleTTL: policy.staleTTL,
            now: now,
            replaceCachedItems: shouldCache)
        if shouldCache {
            self.store(response, for: key, ttl: policy.ttl, now: now)
            if key.hasPrefix("usage:") || key.hasPrefix("cost:") {
                self.lastGood[key] = nil
            } else {
                self.lastGood[key] = LastGoodEntry(recordedAt: now, response: response)
            }
            delivered = response
        } else if let usageMerge {
            delivered = usageMerge.response
            self.lastGood[key] = nil
        } else if let costMerge {
            delivered = costMerge.response
            self.lastGood[key] = nil
        } else {
            delivered = staleResponse ?? response
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
        if key.hasPrefix("cost:") {
            return self.staleCostResponse(for: key, staleTTL: staleTTL, now: now)
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

    private func mergeLastGoodCostItems(
        into response: CLILocalHTTPResponse,
        for key: String,
        staleTTL: TimeInterval,
        now: Date,
        replaceCachedItems: Bool) -> CostMergeResult?
    {
        guard key.hasPrefix("cost:"),
              response.status == .ok,
              staleTTL > 0,
              var items = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        else {
            return nil
        }

        let providers = items.compactMap { item -> String? in
            guard let provider = item["provider"] as? String, !provider.isEmpty else { return nil }
            return provider
        }
        guard providers.count == items.count, Set(providers).count == providers.count else {
            return CostMergeResult(response: response)
        }

        var cachedItems = replaceCachedItems ? [:] : self.lastGoodCostItems[key] ?? [:]
        if !replaceCachedItems {
            cachedItems = cachedItems.filter { now.timeIntervalSince($0.value.recordedAt) <= staleTTL }
        }
        for index in items.indices {
            let provider = providers[index]
            if Self.hasError(items[index]) {
                if let cached = cachedItems[provider],
                   let cachedItem = try? JSONSerialization.jsonObject(with: cached.data) as? [String: Any]
                {
                    items[index] = cachedItem
                }
            } else if let data = try? JSONSerialization.data(withJSONObject: items[index], options: [.sortedKeys]) {
                cachedItems[provider] = LastGoodCostItem(recordedAt: now, data: data)
            }
        }
        self.lastGoodCostItems[key] = cachedItems
        self.lastGoodCostOrder[key] = providers

        guard let body = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else {
            return CostMergeResult(response: response)
        }
        return CostMergeResult(response: CLILocalHTTPResponse(
            status: response.status,
            body: body,
            contentType: response.contentType,
            usageCacheKeys: response.usageCacheKeys))
    }

    private func staleCostResponse(
        for key: String,
        staleTTL: TimeInterval,
        now: Date) -> CLILocalHTTPResponse?
    {
        guard let order = self.lastGoodCostOrder[key], !order.isEmpty,
              let cachedItems = self.lastGoodCostItems[key]
        else {
            return nil
        }
        let rows = order.compactMap { provider -> Any? in
            guard let cached = cachedItems[provider],
                  now.timeIntervalSince(cached.recordedAt) <= staleTTL
            else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: cached.data)
        }
        guard rows.count == order.count,
              let body = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        else {
            return nil
        }
        return CLILocalHTTPResponse(status: .ok, body: body)
    }

    private func store(_ response: CLILocalHTTPResponse, for key: String, ttl: TimeInterval, now: Date) {
        guard ttl > 0, response.status == .ok else { return }
        self.entries[key] = Entry(expiresAt: now.addingTimeInterval(ttl), response: response)
    }

    func cachedEntryCount() -> Int {
        self.entries.count
    }

    func cachedStaleVariantCount() -> Int {
        self.lastGood.count + self.lastGoodUsageItems.count + self.lastGoodCostItems.count
    }
}

private enum CLIServeArgumentError: LocalizedError {
    case invalidHost
    case invalidPort
    case invalidRefreshInterval
    case invalidRequestTimeout
    case emptyDashboardToken(source: String)
    case invalidProvider(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "--host must be 'localhost' or an IPv4 address."
        case .invalidPort:
            "--port must be between 1 and 65535."
        case .invalidRefreshInterval:
            "--refresh-interval must be zero or greater."
        case .invalidRequestTimeout:
            "--request-timeout must be zero or greater."
        case let .emptyDashboardToken(source):
            "\(source) must not be empty or whitespace."
        case let .invalidProvider(provider):
            "Unknown provider '\(provider)'."
        }
    }
}

private struct CLIServeProviderTimeoutError: LocalizedError {
    let provider: UsageProvider

    var errorDescription: String? {
        "\(self.provider.rawValue) usage timed out"
    }
}

private struct CLIServeCostTimeoutError: LocalizedError {
    let provider: UsageProvider

    var errorDescription: String? {
        "\(self.provider.rawValue) cost refresh timed out"
    }
}

extension CodexBarCLI {
    static let defaultServeRequestTimeout: TimeInterval = 30
    static let serveCostRefreshesPricingInBackground = true
    private static let maximumServeRequestTimeout: TimeInterval = 86400

    static func clampedServeRequestTimeout(_ requestTimeout: TimeInterval) -> TimeInterval {
        min(max(requestTimeout, 0), self.maximumServeRequestTimeout)
    }

    static func serveTimeoutResponse() -> CLILocalHTTPResponse {
        self.serveError(status: .gatewayTimeout, message: "request timed out")
    }

    static func runServe(_ values: ParsedValues) async {
        let output = CLIOutputPreferences(format: .json, jsonOnly: true, pretty: false)
        let port = Self.decodeServePort(from: values)
        let host = Self.decodeServeHost(from: values)
        let refreshInterval = Self.decodeServeRefreshInterval(from: values)
        let requestTimeout = Self.decodeServeRequestTimeout(from: values)
        let tokenResolution = Self.resolveDashboardToken(
            from: values,
            environment: ProcessInfo.processInfo.environment)

        guard let port else {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.invalidPort.localizedDescription,
                output: output,
                kind: .args)
        }

        guard let host else {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.invalidHost.localizedDescription,
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

        let dashboardBearer: String?
        switch tokenResolution {
        case .absent:
            dashboardBearer = nil
        case let .token(bearer):
            dashboardBearer = bearer
        case let .empty(source):
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.emptyDashboardToken(source: source).localizedDescription,
                output: output,
                kind: .args)
        }

        let bindHost = CLIServeSecurity.bindHost(host)
        let allowPlainHTTP = Self.decodeServeAllowPlainHTTP(from: values)
        if let startupError = Self.validateServeStartup(
            host: bindHost,
            hasConfiguredBearer: dashboardBearer != nil,
            allowPlainHTTP: allowPlainHTTP)
        {
            Self.exit(
                code: .failure,
                message: startupError.localizedDescription,
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
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: refreshInterval,
            requestTimeout: requestTimeout,
            healthVersion: Self.currentVersion(),
            dashboardAuth: CLIServeDashboardAuth(bearer: dashboardBearer),
            bindHost: bindHost)
        let server = CLILocalHTTPServer(
            host: bindHost,
            port: port,
            allowedHosts: CLIServeSecurity.allowedHosts(forBindHost: bindHost))
        { request in
            await Self.handleServeRequest(request, runtime: runtime)
        }
        let signalMonitor = CLITerminationSignalMonitor { _ in
            TTYCommandRunner.terminateActiveProcessesForAppShutdown()
            server.stop()
        }
        defer { signalMonitor.cancel() }

        do {
            try await server.run {
                Self.writeStderr("CodexBar server listening on http://\(bindHost):\(port)\n")
                if !CLIServeSecurity.isLoopbackHost(bindHost) {
                    Self.writeStderr(
                        "Warning: plain HTTP on a non-loopback host; the bearer token gating "
                            + "/usage, /cost, and /dashboard/v1/snapshot crosses the network "
                            + "in cleartext on every request.\n")
                }
            }
        } catch {
            await Self.shutdownServeRuntime(runtime)
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
        await Self.shutdownServeRuntime(runtime)
    }

    private static func shutdownServeRuntime(_ runtime: ServeRuntime) async {
        await runtime.cache.operations.shutdown()
        await runtime.providerOperations.shutdown()
        await runtime.costOperations.shutdown()
        await ProviderCLISessionLifecycle.shutdownPersistentSessions()
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
    }

    static let dashboardTokenEnvironmentVariable = "CODEXBAR_DASHBOARD_TOKEN"

    enum CLIServeDashboardTokenResolution: Equatable {
        case absent
        case token(String)
        /// The named source supplied an empty or whitespace-only token.
        case empty(source: String)
    }

    /// Resolves the dashboard token, preferring the environment variable over
    /// `--dashboard-token` (a token in argv leaks through `ps`). Empty or
    /// whitespace-only values are startup errors rather than silent no-token modes.
    static func resolveDashboardToken(
        from values: ParsedValues,
        environment: [String: String]) -> CLIServeDashboardTokenResolution
    {
        if let raw = environment[dashboardTokenEnvironmentVariable] {
            let bearer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return bearer.isEmpty
                ? .empty(source: Self.dashboardTokenEnvironmentVariable)
                : .token(bearer)
        }
        guard let raw = values.options["dashboardBearer"]?.last else { return .absent }
        let bearer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return bearer.isEmpty ? .empty(source: "--dashboard-token") : .token(bearer)
    }

    static func decodeServeHost(from values: ParsedValues) -> String? {
        let raw = values.options["host"]?.last ?? "127.0.0.1"
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let bindHost = CLIServeSecurity.bindHost(host)
        return CLIServeSecurity.isSupportedIPv4BindHost(bindHost) ? host : nil
    }

    static func decodeServeAllowPlainHTTP(from values: ParsedValues) -> Bool {
        // Parsed keys are the ServeOptions property names, not the kebab-case
        // option names: `allowPlainHTTP` for --allow-plain-http.
        values.flags.contains("allowPlainHTTP")
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
        guard parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    static func handleServeRequest(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime) async -> CLILocalHTTPResponse
    {
        let startedAt = ContinuousClock().now
        let requestDeadline = Self.serveRequestDeadline(
            startedAt: startedAt,
            requestTimeout: runtime.requestTimeout)
        let providerTimeout = Self.serveProviderTimeout(requestTimeout: runtime.requestTimeout)
        let providerDeadline = Self.serveProviderDeadline(
            startedAt: startedAt,
            requestTimeout: runtime.requestTimeout)
        let route: CLIServeRoute
        do {
            route = try CLIServeRouter.route(
                method: request.method,
                path: request.path,
                queryItems: request.queryItems)
        } catch CLIServeRouteError.methodNotAllowed {
            let response = Self.serveError(status: .methodNotAllowed, message: "method not allowed")
            return request.path.hasPrefix("/dashboard/v1/") ? Self.addingNoStore(response) : response
        } catch {
            let response = Self.serveError(status: .notFound, message: "not found")
            return request.path.hasPrefix("/dashboard/v1/") ? Self.addingNoStore(response) : response
        }

        switch route {
        case .health:
            return Self.serveHealthResponse(version: runtime.healthVersion)
        case let .usage(provider):
            // On non-loopback binds every data route requires the bearer token,
            // checked before any cache access so unauthenticated requests can
            // neither warm nor read account data.
            guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
                return Self.serveUnauthorizedResponse()
            }
            let snapshot: CLIServeConfigSnapshot
            let operationKey: String
            do {
                snapshot = try Self.loadServeConfigSnapshot(configStore: runtime.configStore)
                operationKey = try Self.serveOperationKey(kind: "usage", provider: provider)
            } catch {
                let status: CLIHTTPStatus = error is CLIServeArgumentError ? .badRequest : .internalServerError
                return Self.addingNoStore(Self.serveError(status: status, message: error.localizedDescription))
            }
            return await Self.addingNoStore(Self.cachedServeResponse(
                request: ServeResponseRequest(
                    key: operationKey,
                    configFingerprint: snapshot.cacheToken,
                    refreshInterval: runtime.refreshInterval,
                    deadline: requestDeadline),
                cache: runtime.cache,
                makeResponse: {
                    await Self.serveUsage(
                        provider: provider,
                        context: ServeUsageContext(
                            config: snapshot.config,
                            configFingerprint: snapshot.cacheToken,
                            refreshInterval: runtime.refreshInterval,
                            providerTimeout: providerTimeout,
                            providerDeadline: providerDeadline,
                            providerOperations: runtime.providerOperations))
                }))
        case let .cost(provider):
            guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
                return Self.serveUnauthorizedResponse()
            }
            let snapshot: CLIServeConfigSnapshot
            let operationKey: String
            do {
                snapshot = try Self.loadServeConfigSnapshot(configStore: runtime.configStore)
                operationKey = try Self.serveOperationKey(kind: "cost", provider: provider)
            } catch {
                let status: CLIHTTPStatus = error is CLIServeArgumentError ? .badRequest : .internalServerError
                return Self.addingNoStore(Self.serveError(status: status, message: error.localizedDescription))
            }
            return await Self.addingNoStore(Self.cachedServeResponse(
                request: ServeResponseRequest(
                    key: operationKey,
                    configFingerprint: snapshot.cacheToken,
                    refreshInterval: runtime.refreshInterval,
                    deadline: requestDeadline),
                cache: runtime.cache,
                makeResponse: {
                    await Self.serveCost(
                        provider: provider,
                        context: ServeCostContext(
                            config: snapshot.config,
                            collection: ServeCostCollectionContext(
                                configFingerprint: snapshot.cacheToken,
                                providerTimeout: providerTimeout,
                                requestDeadline: requestDeadline,
                                now: { ContinuousClock().now },
                                providerOperations: runtime.costOperations)))
                }))
        case .dashboardSnapshot:
            // Auth comes first: an unauthenticated request must not warm, read, or
            // deduplicate against the response cache.
            guard runtime.dashboardAuth.authorize(request) else {
                return Self.serveUnauthorizedResponse()
            }
            let snapshot: CLIServeConfigSnapshot
            let operationKey: String
            do {
                snapshot = try Self.loadServeConfigSnapshot(configStore: runtime.configStore)
                operationKey = try Self.serveOperationKey(kind: "dashboard", provider: nil)
            } catch {
                let status: CLIHTTPStatus = error is CLIServeArgumentError ? .badRequest : .internalServerError
                return Self.addingNoStore(Self.serveError(status: status, message: error.localizedDescription))
            }
            return await Self.addingNoStore(Self.cachedServeResponse(
                request: ServeResponseRequest(
                    key: operationKey,
                    configFingerprint: snapshot.cacheToken,
                    refreshInterval: runtime.refreshInterval,
                    deadline: requestDeadline),
                cache: runtime.cache,
                makeResponse: {
                    await Self.serveDashboardSnapshot(
                        context: ServeDashboardContext(
                            config: snapshot.config,
                            usage: ServeUsageContext(
                                config: snapshot.config,
                                configFingerprint: snapshot.cacheToken,
                                refreshInterval: runtime.refreshInterval,
                                providerTimeout: providerTimeout,
                                providerDeadline: providerDeadline,
                                providerOperations: runtime.providerOperations,
                                includeAllCodexAccounts: false),
                            costCollection: ServeCostCollectionContext(
                                configFingerprint: snapshot.cacheToken,
                                providerTimeout: providerTimeout,
                                requestDeadline: requestDeadline,
                                now: { ContinuousClock().now },
                                providerOperations: runtime.costOperations),
                            codexBarVersion: runtime.healthVersion))
                }))
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

    static func serveOperationKey(kind: String, provider: String?) throws -> String {
        guard let provider else { return "\(kind):default" }
        guard let selection = ProviderSelection(argument: provider) else {
            throw CLIServeArgumentError.invalidProvider(provider)
        }
        return "\(kind):\(selection.asList.map(\.rawValue).joined(separator: ","))"
    }

    static func serveCacheKey(operationKey: String, configToken: String) -> String {
        "\(operationKey):\(configToken)"
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
        await self.cachedServeResponse(
            request: ServeResponseRequest(
                key: key,
                configFingerprint: "",
                refreshInterval: refreshInterval,
                deadline: self.serveRequestDeadline(
                    startedAt: ContinuousClock().now,
                    requestTimeout: requestTimeout)),
            cache: cache,
            makeResponse: makeResponse)
    }

    private static func cachedServeResponse(
        request: ServeResponseRequest,
        cache: CLIServeResponseCache,
        makeResponse: @Sendable @escaping () async -> CLILocalHTTPResponse) async -> CLILocalHTTPResponse
    {
        let cacheKey = Self.serveCacheKey(
            operationKey: request.key,
            configToken: request.configFingerprint)
        if let response = await cache.cachedResponse(for: cacheKey, now: Date()) {
            return response
        }

        let timeoutResponse = Self.serveTimeoutResponse()
        let outcome = await cache.operations.value(
            for: request.key,
            fingerprint: request.configFingerprint,
            deadline: request.deadline,
            timeoutValue: CLIServeCoordinatedResponse(response: timeoutResponse, isCommitted: false),
            accept: { fetched in
                let committed = await cache.completeFetch(
                    fetched.response,
                    for: cacheKey,
                    policy: CLIServeResponseCache.CachePolicy(
                        ttl: request.refreshInterval,
                        staleTTL: Self.serveStaleTTL(refreshInterval: request.refreshInterval)),
                    now: Date(),
                    shouldCache: Self.shouldCacheServeResponse(fetched.response))
                return CLIServeCoordinatedResponse(response: committed, isCommitted: true)
            },
            operation: {
                if let response = await cache.cachedResponse(for: cacheKey, now: Date()) {
                    return CLIServeCoordinatedResponse(response: response, isCommitted: false)
                }
                let response = await makeResponse()
                return CLIServeCoordinatedResponse(response: response, isCommitted: false)
            })
        if outcome.isCommitted {
            return outcome.response
        }
        // Timeout values are selected while the abandoned source stays owned.
        // Project them through stale-row policy here; they contain no source
        // result that could overwrite a newer generation.
        return await cache.completeFetch(
            outcome.response,
            for: cacheKey,
            policy: CLIServeResponseCache.CachePolicy(
                ttl: request.refreshInterval,
                staleTTL: Self.serveStaleTTL(refreshInterval: request.refreshInterval)),
            now: Date(),
            shouldCache: Self.shouldCacheServeResponse(outcome.response))
    }

    static func serveRequestDeadline(
        startedAt: ContinuousClock.Instant,
        requestTimeout: TimeInterval) -> ContinuousClock.Instant?
    {
        let timeout = Self.clampedServeRequestTimeout(requestTimeout)
        guard timeout > 0 else { return nil }
        return startedAt.advanced(by: .seconds(timeout))
    }

    static func serveProviderDeadline(
        startedAt: ContinuousClock.Instant,
        requestTimeout: TimeInterval) -> ContinuousClock.Instant?
    {
        guard let timeout = self.serveProviderTimeout(requestTimeout: requestTimeout) else { return nil }
        return startedAt.advanced(by: .seconds(timeout))
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
        context: ServeUsageContext) async -> CLILocalHTTPResponse
    {
        let selection: ProviderSelection
        do {
            selection = try Self.serveProviderSelection(rawProvider: rawProvider, config: context.config)
        } catch {
            return Self.serveError(status: .badRequest, message: error.localizedDescription)
        }

        let output: UsageCommandOutput
        do {
            output = try await Self.serveUsageOutput(selection: selection, context: context)
        } catch {
            return Self.serveError(status: .internalServerError, message: error.localizedDescription)
        }

        return Self.serveJSON(
            output.payload,
            usageCacheKeys: output.payload.map(\.cacheAccountKey))
    }

    private static func serveUsageOutput(
        selection: ProviderSelection,
        context: ServeUsageContext) async throws -> UsageCommandOutput
    {
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: context.config,
            verbose: false)

        let browserDetection = BrowserDetection()
        let command = UsageCommandContext(
            format: .json,
            includeCredits: true,
            sourceModeOverride: nil,
            antigravityPlanDebug: false,
            augmentDebug: false,
            webDebugDumpHTML: false,
            webTimeout: context.providerTimeout ?? 60,
            verbose: false,
            useColor: false,
            resetStyle: Self.resetTimeDisplayStyleFromDefaults(),
            weeklyWorkDays: Self.weeklyProgressWorkDaysFromDefaults(),
            jsonOnly: true,
            includeAllCodexAccounts: context.includeAllCodexAccounts,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            persistCLISessions: true,
            persistentCLISessionIdleWindow: Self.serveCLISessionIdleWindow(
                refreshInterval: context.refreshInterval))

        return await Self.serveCollectUsageOutputs(
            providers: selection.asList,
            configFingerprint: Self.serveUsageOperationFingerprint(
                configFingerprint: context.configFingerprint,
                includeAllCodexAccounts: context.includeAllCodexAccounts),
            deadline: context.providerDeadline,
            operations: context.providerOperations)
        { provider in
            await ProviderInteractionContext.$current.withValue(.background) {
                await Self.fetchUsageOutputs(
                    provider: provider,
                    status: nil,
                    tokenContext: tokenContext,
                    command: command)
            }
        }
    }

    static func serveUsageOperationFingerprint(
        configFingerprint: String,
        includeAllCodexAccounts: Bool) -> String
    {
        "\(configFingerprint):codex-accounts=\(includeAllCodexAccounts ? "all" : "selected")"
    }

    /// Builds the token-gated dashboard snapshot. Reuses the same coordinated
    /// usage/cost collection as `/usage` and `/cost` — per-provider budgets,
    /// in-flight dedup, and config fingerprints all apply unchanged — then
    /// projects the results through `DashboardSnapshotBuilder`.
    private static func serveDashboardSnapshot(context: ServeDashboardContext) async -> CLILocalHTTPResponse {
        let selection = Self.providerSelection(
            rawOverride: nil,
            enabled: context.config.enabledProviders())

        let usageOutput: UsageCommandOutput
        do {
            usageOutput = try await Self.serveUsageOutput(selection: selection, context: context.usage)
        } catch {
            return Self.serveError(status: .internalServerError, message: error.localizedDescription)
        }

        let costProviders = Self.costProviders(from: selection)
        let fetcher = CostUsageFetcher()
        let costPayloads = await Self.serveCollectCostPayloads(
            providers: costProviders,
            context: context.costCollection)
        { provider in
            do {
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    forceRefresh: false,
                    refreshPricingInBackground: Self.serveCostRefreshesPricingInBackground)
                return Self.makeCostPayload(provider: provider, snapshot: snapshot, error: nil)
            } catch {
                return Self.makeCostPayload(provider: provider, snapshot: nil, error: error)
            }
        }

        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: usageOutput.payload,
            costPayloads: costPayloads,
            config: context.config,
            identityMode: .redacted,
            generatedAt: Date(),
            refreshInterval: context.usage.refreshInterval,
            codexBarVersion: context.codexBarVersion)

        // Cache-Control: no-store is applied uniformly at the route level.
        return Self.serveJSON(
            snapshot,
            usageCacheKeys: usageOutput.payload.map(\.cacheAccountKey))
    }

    /// Per-provider fetch budget for `/usage` and `/cost`. Finite provider work
    /// is bounded below the outer request deadline so the empty 504 stays a last resort.
    /// `nil` preserves the documented disabled serve deadline without changing
    /// provider-specific internal timeouts.
    static func serveProviderTimeout(requestTimeout: TimeInterval) -> TimeInterval? {
        guard requestTimeout > 0, requestTimeout.isFinite else { return nil }
        let clampedTimeout = min(requestTimeout, Self.maximumServeRequestTimeout)
        // 0.8x keeps the budget strictly below the finite deadline at every
        // value (including sub-second and capped timeouts), so the empty-504
        // deadline can never preempt a provider's own bound.
        return clampedTimeout * 0.8
    }

    /// Collects usage for each provider concurrently. When `deadline` is non-nil,
    /// a provider that exceeds its budget contributes a provider error
    /// row instead of blocking the others, so the overall response still renders
    /// every healthy provider. (Per-account error rows that carry a
    /// cache key are merged with last-known-good by `CLIServeResponseCache`; a
    /// timeout row is account-agnostic and is not reconstructed, matching the
    /// existing "a timeout cannot prove the active account" cache rule.) Each
    /// deadline is absolute from HTTP request entry. The operation coordinator
    /// retains timed-out sources until they really exit, preventing a later route
    /// from stacking work for that provider. Results are merged in caller order.
    static func serveCollectUsageOutputs(
        providers: [UsageProvider],
        providerTimeout: TimeInterval?,
        fetch: @Sendable @escaping (UsageProvider) async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        let deadline = providerTimeout.map {
            ContinuousClock().now.advanced(by: .seconds(max(0, $0)))
        }
        return await Self.serveCollectUsageOutputs(
            providers: providers,
            configFingerprint: "",
            deadline: deadline,
            operations: CLIServeOperationCoordinator(),
            fetch: fetch)
    }

    static func serveCollectUsageOutputs(
        providers: [UsageProvider],
        configFingerprint: String,
        deadline: ContinuousClock.Instant?,
        operations: CLIServeOperationCoordinator<UsageCommandOutput>,
        fetch: @Sendable @escaping (UsageProvider) async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        let indexed = await withTaskGroup(of: (Int, UsageCommandOutput).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let timeout = Self.serveProviderTimeoutOutput(provider: provider)
                    let output = await operations.value(
                        for: provider.rawValue,
                        fingerprint: configFingerprint,
                        deadline: deadline,
                        timeoutValue: timeout)
                    {
                        await fetch(provider)
                    }
                    return (index, output)
                }
            }
            var collected: [(Int, UsageCommandOutput)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        var output = UsageCommandOutput()
        for (_, providerOutput) in indexed.sorted(by: { $0.0 < $1.0 }) {
            output.merge(providerOutput)
        }
        return output
    }

    /// Provider-level error row for a fetch that exceeded its per-provider budget.
    static func serveProviderTimeoutOutput(provider: UsageProvider) -> UsageCommandOutput {
        var output = UsageCommandOutput()
        output.exitCode = .failure
        output.payload.append(Self.makeProviderErrorPayload(
            provider: provider,
            account: nil,
            source: "auto",
            status: nil,
            error: CLIServeProviderTimeoutError(provider: provider),
            kind: .provider))
        return output
    }

    private static func serveCost(
        provider rawProvider: String?,
        context: ServeCostContext) async -> CLILocalHTTPResponse
    {
        let selection: ProviderSelection
        do {
            selection = try Self.serveProviderSelection(rawProvider: rawProvider, config: context.config)
        } catch {
            return Self.serveError(status: .badRequest, message: error.localizedDescription)
        }

        let providers = Self.costProviders(from: selection)
        guard !providers.isEmpty else {
            return Self.serveError(
                status: .badRequest,
                message: "cost is only supported for \(Self.costSupportedProviderNames())")
        }

        // Cursor cost honors the same cookie policy here as the `cost` command: return a provider
        // error when the source is Off and forward the Manual header for an enabled fetch.
        let cursorCookieSettings: ProviderSettingsSnapshot.CursorProviderSettings?
        let cursorCookieSettingsError: Error?
        do {
            cursorCookieSettings = try Self.cursorCookieSettings(config: context.config, providers: providers)
            cursorCookieSettingsError = nil
        } catch {
            cursorCookieSettings = nil
            cursorCookieSettingsError = error
        }
        let fetcher = CostUsageFetcher()
        let payload = await Self.serveCollectCostPayloads(
            providers: providers,
            context: context.collection)
        { provider in
            if let error = Self.cursorCostAvailabilityError(
                provider,
                settings: cursorCookieSettings,
                resolutionError: cursorCookieSettingsError)
            {
                return Self.makeCostPayload(provider: provider, snapshot: nil, error: error)
            }
            do {
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    forceRefresh: false,
                    cursorCookieHeaderOverride: Self.cursorCostHeaderOverride(
                        provider,
                        settings: cursorCookieSettings),
                    refreshPricingInBackground: Self.serveCostRefreshesPricingInBackground)
                return Self.makeCostPayload(provider: provider, snapshot: snapshot, error: nil)
            } catch {
                return Self.makeCostPayload(provider: provider, snapshot: nil, error: error)
            }
        }

        return Self.serveJSON(payload)
    }

    static func serveCollectCostPayloads(
        providers: [UsageProvider],
        context: ServeCostCollectionContext,
        fetch: @Sendable @escaping (UsageProvider) async -> CostPayload) async -> [CostPayload]
    {
        // Preserve the established scan order. Pricing refresh stays best-effort
        // background work so network latency never consumes a provider deadline;
        // consecutive scans can still overlap that bounded adjacent work.
        var payload: [CostPayload] = []
        for provider in providers {
            let deadline = Self.serveCostProviderDeadline(
                startedAt: context.now(),
                providerTimeout: context.providerTimeout,
                requestDeadline: context.requestDeadline)
            let timeout = Self.makeCostPayload(
                provider: provider,
                snapshot: nil,
                error: CLIServeCostTimeoutError(provider: provider))
            let item = await context.providerOperations.value(
                for: provider.rawValue,
                fingerprint: context.configFingerprint,
                deadline: deadline,
                timeoutValue: timeout)
            {
                await fetch(provider)
            }
            payload.append(item)
        }
        return payload
    }

    /// Gives a sequential cost scan its full provider budget from the point it
    /// actually starts, without allowing the overall HTTP request to overrun.
    static func serveCostProviderDeadline(
        startedAt: ContinuousClock.Instant,
        providerTimeout: TimeInterval?,
        requestDeadline: ContinuousClock.Instant?) -> ContinuousClock.Instant?
    {
        guard let providerTimeout else { return requestDeadline }
        let providerDeadline = startedAt.advanced(by: .seconds(max(0, providerTimeout)))
        guard let requestDeadline else { return providerDeadline }
        return min(providerDeadline, requestDeadline)
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

    /// The data routes (`/usage`, `/cost`, `/dashboard/v1/snapshot`) carry account
    /// data; keep every response on them out of shared HTTP caches. Idempotent:
    /// responses that already declare a Cache-Control policy (e.g. 401s) pass
    /// through unchanged.
    static func addingNoStore(_ response: CLILocalHTTPResponse) -> CLILocalHTTPResponse {
        guard !response.extraHeaders.contains(where: { $0.0.lowercased() == "cache-control" }) else {
            return response
        }
        return CLILocalHTTPResponse(
            status: response.status,
            body: response.body,
            contentType: response.contentType,
            extraHeaders: response.extraHeaders + [("Cache-Control", "no-store")],
            usageCacheKeys: response.usageCacheKeys)
    }

    /// 401 for the dashboard routes: advertises the bearer scheme and keeps the
    /// response out of caches, matching the snapshot responses it guards.
    static func serveUnauthorizedResponse() -> CLILocalHTTPResponse {
        self.serveJSON(
            ServeErrorPayload(error: "unauthorized"),
            status: .unauthorized,
            extraHeaders: [
                ("WWW-Authenticate", "Bearer"),
                ("Cache-Control", "no-store"),
            ])
    }

    private static func serveJSON(
        _ payload: some Encodable,
        status: CLIHTTPStatus = .ok,
        extraHeaders: [(String, String)] = [],
        usageCacheKeys: [String?]? = nil) -> CLILocalHTTPResponse
    {
        let json = Self.encodeJSON(payload, pretty: false) ?? "{}"
        return CLILocalHTTPResponse(
            status: status,
            body: Data(json.utf8),
            extraHeaders: extraHeaders,
            usageCacheKeys: usageCacheKeys)
    }

    private static func serveError(status: CLIHTTPStatus, message: String) -> CLILocalHTTPResponse {
        self.serveJSON(ServeErrorPayload(error: message), status: status)
    }
}
