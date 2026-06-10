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

    @Option(name: .long("host"), help: "HTTP bind host (default: 127.0.0.1)")
    var host: String?

    @Option(name: .long("refresh-interval"), help: "Response cache TTL in seconds (default: 60)")
    var refreshInterval: Double?

    @Option(
        name: .long("request-timeout"),
        help: "Total per-request deadline in seconds; 0 disables (default: 30)")
    var requestTimeout: Double?

    @Option(name: .long("dashboard-token"), help: "Bearer token for serve data routes")
    var dashboardToken: String?

    @Flag(name: .long("dashboard-pairing"), help: "Enable short-code dashboard pairing")
    var dashboardPairing: Bool = false

    @Option(name: .long("dashboard-identity"), help: "Dashboard identity exposure: none | redacted | full")
    var dashboardIdentity: String?
}

enum CLIServeRoute: Equatable {
    case health
    case usage(provider: String?)
    case cost(provider: String?)
    case dashboardSnapshot
    case dashboardPairing
    case dashboardPairingClaim
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
        case "/dashboard/v1/pairing":
            return .dashboardPairing
        case "/dashboard/v1/pairing/claim":
            return .dashboardPairingClaim
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

private enum CLIServeCacheLookup {
    case response(CLILocalHTTPResponse)
    case miss
}

actor CLIServeResponseCache {
    private struct Entry {
        let expiresAt: Date
        let response: CLILocalHTTPResponse
    }

    private var entries: [String: Entry] = [:]
    private var inFlightKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<CLIServeCacheLookup, Never>]] = [:]

    private func response(for key: String, now: Date) -> CLILocalHTTPResponse? {
        guard let entry = self.entries[key] else { return nil }
        guard entry.expiresAt > now else {
            self.entries[key] = nil
            return nil
        }
        return entry.response
    }

    fileprivate func responseOrStartFetch(for key: String, now: Date) async -> CLIServeCacheLookup {
        if let cached = self.response(for: key, now: now) {
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

    fileprivate func completeFetch(
        _ response: CLILocalHTTPResponse,
        for key: String,
        ttl: TimeInterval,
        now: Date,
        shouldCache: Bool)
    {
        if shouldCache {
            self.store(response, for: key, ttl: ttl, now: now)
        }
        self.inFlightKeys.remove(key)
        let waiters = self.waiters.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume(returning: .response(response))
        }
    }

    private func store(_ response: CLILocalHTTPResponse, for key: String, ttl: TimeInterval, now: Date) {
        guard ttl > 0, response.status == .ok else { return }
        self.entries[key] = Entry(expiresAt: now.addingTimeInterval(ttl), response: response)
    }
}

actor CLIServeDashboardSnapshotCache {
    private struct Entry {
        let cacheKey: String
        let expiresAt: Date
        let response: CLILocalHTTPResponse
    }

    private var entry: Entry?
    private var refreshingKeys: Set<String> = []

    func response(for cacheKey: String, now: Date) -> CLILocalHTTPResponse? {
        guard let entry, entry.cacheKey == cacheKey, entry.expiresAt > now else { return nil }
        return entry.response
    }

    func staleResponse(for cacheKey: String) -> CLILocalHTTPResponse? {
        guard let entry, entry.cacheKey == cacheKey else { return nil }
        return entry.response
    }

    func beginRefresh(for cacheKey: String) -> Bool {
        guard !self.refreshingKeys.contains(cacheKey) else { return false }
        self.refreshingKeys.insert(cacheKey)
        return true
    }

    func finishRefresh(response: CLILocalHTTPResponse, for cacheKey: String, ttl: TimeInterval, now: Date) {
        self.refreshingKeys.remove(cacheKey)
        guard ttl > 0, response.status == .ok else { return }
        self.entry = Entry(cacheKey: cacheKey, expiresAt: now.addingTimeInterval(ttl), response: response)
    }
}

private enum CLIServeArgumentError: LocalizedError {
    case invalidHost
    case invalidPort
    case invalidRefreshInterval
    case invalidRequestTimeout
    case invalidDashboardIdentity
    case missingDashboardToken(String)
    case invalidProvider(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "--host must not be empty."
        case .invalidPort:
            "--port must be between 1 and 65535."
        case .invalidRefreshInterval:
            "--refresh-interval must be zero or greater."
        case .invalidRequestTimeout:
            "--request-timeout must be zero or greater."
        case .invalidDashboardIdentity:
            "--dashboard-identity must be none, redacted, or full."
        case let .missingDashboardToken(host):
            "--dashboard-token is required when --host is non-loopback ('\(host)')."
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
        let host = Self.decodeServeHost(from: values)
        let refreshInterval = Self.decodeServeRefreshInterval(from: values)
        let requestTimeout = Self.decodeServeRequestTimeout(from: values)
        let dashboardToken = Self.decodeDashboardToken(from: values)
        let dashboardPairingEnabled = Self.decodeDashboardPairingEnabled(from: values)
        let dashboardIdentity = Self.decodeDashboardIdentity(from: values)

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

        guard let dashboardIdentity else {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.invalidDashboardIdentity.localizedDescription,
                output: output,
                kind: .args)
        }

        if CLIServeSecurity.requiresDashboardToken(host: host), dashboardToken == nil, !dashboardPairingEnabled {
            Self.exit(
                code: .failure,
                message: CLIServeArgumentError.missingDashboardToken(host).localizedDescription,
                output: output,
                kind: .args)
        }

        let cache = CLIServeResponseCache()
        let dashboardCache = CLIServeDashboardSnapshotCache()
        let pairing = dashboardPairingEnabled ? CLIServePairing(announce: { Self.writeStderr($0) }) : nil
        let auth = CLIServeAuth(dashboardToken: dashboardToken, pairing: pairing)
        let bindHost = CLIServeSecurity.bindHost(host)
        let allowNonLoopbackHostHeaders = !CLIServeSecurity.isLoopbackHost(host)
        let server = CLILocalHTTPServer(
            host: bindHost,
            port: port,
            allowNonLoopbackHostHeaders: allowNonLoopbackHostHeaders)
        { request in
            await Self.handleServeRequest(
                request,
                output: output,
                cache: cache,
                dashboardCache: dashboardCache,
                refreshInterval: refreshInterval,
                requestTimeout: requestTimeout,
                auth: auth,
                dashboardIdentity: dashboardIdentity)
        }

        do {
            try await server.run {
                Self.writeStderr("CodexBar server listening on http://\(bindHost):\(port)\n")
                if let pairing, let code = pairing.currentCode() {
                    Self.writeStderr("Dashboard pairing code: \(code)\n")
                }
            }
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
    }

    static func decodeServeHost(from values: ParsedValues) -> String? {
        let raw = values.options["host"]?.last ?? "127.0.0.1"
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
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

        let staleBase = parsed.rounded(.up)
        let refreshSeconds = parsed.rounded()
        guard staleBase <= Double(Int.max / 3), refreshSeconds <= Double(Int.max) else { return nil }
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

    static func decodeDashboardToken(from values: ParsedValues) -> String? {
        guard let raw = values.options["dashboardToken"]?.last else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func decodeDashboardPairingEnabled(from values: ParsedValues) -> Bool {
        values.flags.contains("dashboardPairing")
    }

    static func decodeDashboardIdentity(from values: ParsedValues) -> DashboardIdentityMode? {
        let raw = values.options["dashboardIdentity"]?.last ?? DashboardIdentityMode.redacted.rawValue
        return DashboardIdentityMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    // swiftlint:disable:next function_parameter_count
    private static func handleServeRequest(
        _ request: CLILocalHTTPRequest,
        output: CLIOutputPreferences,
        cache: CLIServeResponseCache,
        dashboardCache: CLIServeDashboardSnapshotCache,
        refreshInterval: TimeInterval,
        requestTimeout: TimeInterval,
        auth: CLIServeAuth,
        dashboardIdentity: DashboardIdentityMode) async -> CLILocalHTTPResponse
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
            return Self.serveJSON(ServeHealthPayload(status: "ok"))
        case .dashboardPairing:
            guard let pairing = auth.pairing, let payload = pairing.discoveryPayload() else {
                return Self.serveError(status: .notFound, message: "pairing unavailable")
            }
            return Self.serveJSON(payload)
        case .dashboardPairingClaim:
            guard let pairing = auth.pairing else {
                return Self.serveError(status: .notFound, message: "pairing unavailable")
            }
            switch pairing.claim(
                pairingID: request.queryItems["pairingId"],
                code: request.queryItems["code"])
            {
            case let .claimed(payload):
                return Self.serveJSON(payload)
            case .rejected:
                return Self.serveError(status: .unauthorized, message: "invalid pairing code")
            case .unavailable:
                return Self.serveError(status: .notFound, message: "pairing unavailable")
            }
        case let .usage(provider):
            guard auth.authorizeDataRequest(request) else {
                return Self.serveError(status: .unauthorized, message: "unauthorized")
            }
            let config = Self.loadConfig(output: output)
            let configKey = Self.serveConfigCacheKey(config)
            return await Self.cachedServeResponse(
                key: "usage:\(configKey):\(provider ?? "")",
                cache: cache,
                refreshInterval: refreshInterval,
                requestTimeout: requestTimeout)
            {
                await Self.serveUsage(provider: provider, config: config)
            }
        case let .cost(provider):
            guard auth.authorizeDataRequest(request) else {
                return Self.serveError(status: .unauthorized, message: "unauthorized")
            }
            let config = Self.loadConfig(output: output)
            let configKey = Self.serveConfigCacheKey(config)
            return await Self.cachedServeResponse(
                key: "cost:\(configKey):\(provider ?? "")",
                cache: cache,
                refreshInterval: refreshInterval,
                requestTimeout: requestTimeout)
            {
                await Self.serveCost(provider: provider, config: config)
            }
        case .dashboardSnapshot:
            guard auth.authorizeDataRequest(request) else {
                return Self.serveError(status: .unauthorized, message: "unauthorized")
            }
            let config = Self.loadConfig(output: output)
            return await Self.serveCachedDashboardSnapshot(
                config: config,
                cache: dashboardCache,
                refreshInterval: refreshInterval,
                identityMode: dashboardIdentity)
        }
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
            await cache.completeFetch(
                response,
                for: key,
                ttl: refreshInterval,
                now: Date(),
                shouldCache: Self.shouldCacheServeResponse(response))
            return response
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

    static func shouldCacheServeResponse(_ response: CLILocalHTTPResponse) -> Bool {
        guard response.status == .ok else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: response.body) else {
            return true
        }
        if let providers = payload as? [[String: Any]] {
            return !providers.contains { item in
                guard let error = item["error"] else { return false }
                return !(error is NSNull)
            }
        }
        return true
    }

    static func serveConfigCacheKey(_ config: CodexBarConfig) -> String {
        config.enabledProviders().map(\.rawValue).joined(separator: ",")
    }

    static func serveCachedDashboardSnapshot(
        config: CodexBarConfig,
        cache: CLIServeDashboardSnapshotCache,
        refreshInterval: TimeInterval,
        identityMode: DashboardIdentityMode) async -> CLILocalHTTPResponse
    {
        let cacheKey = "\(identityMode.rawValue):\(Self.serveConfigCacheKey(config))"
        if let response = await cache.response(for: cacheKey, now: Date()) {
            return response
        }

        await Self.startDashboardSnapshotRefresh(
            config: config,
            cache: cache,
            cacheKey: cacheKey,
            refreshInterval: refreshInterval,
            identityMode: identityMode)

        if let response = await cache.staleResponse(for: cacheKey) {
            return response
        }

        return Self.serveJSON(Self.makeDashboardRefreshingSnapshot(
            config: config,
            refreshInterval: refreshInterval,
            identityMode: identityMode))
    }

    private static func startDashboardSnapshotRefresh(
        config: CodexBarConfig,
        cache: CLIServeDashboardSnapshotCache,
        cacheKey: String,
        refreshInterval: TimeInterval,
        identityMode: DashboardIdentityMode) async
    {
        guard await cache.beginRefresh(for: cacheKey) else { return }
        Task {
            let response = await Self.serveDashboardSnapshot(
                config: config,
                refreshInterval: refreshInterval,
                identityMode: identityMode)
            await cache.finishRefresh(response: response, for: cacheKey, ttl: refreshInterval, now: Date())
        }
    }

    static func makeDashboardRefreshingSnapshot(
        config: CodexBarConfig,
        refreshInterval: TimeInterval,
        identityMode: DashboardIdentityMode) -> DashboardSnapshotPayload
    {
        let generatedAt = Date()
        let providers = config.enabledProviders().map { provider in
            ProviderPayload(
                provider: provider,
                account: nil,
                version: nil,
                source: "refreshing",
                status: nil,
                usage: nil,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: ProviderErrorPayload(code: 0, message: "refreshing", kind: .provider))
        }
        return DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: providers,
            costPayloads: [],
            config: config,
            identityMode: identityMode,
            generatedAt: generatedAt,
            refreshInterval: refreshInterval,
            codexBarVersion: Self.currentVersion())
    }

    private static func serveUsage(
        provider rawProvider: String?,
        config: CodexBarConfig) async -> CLILocalHTTPResponse
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
            jsonOnly: true,
            includeAllCodexAccounts: true,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)

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

        return Self.serveJSON(output.payload)
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

    private static func serveDashboardSnapshot(
        config: CodexBarConfig,
        refreshInterval: TimeInterval,
        identityMode: DashboardIdentityMode) async -> CLILocalHTTPResponse
    {
        let selection = Self.providerSelection(rawOverride: nil, enabled: config.enabledProviders())
        let usagePayloads = await Self.dashboardUsagePayloads(selection: selection, config: config)
        let costPayloads = await Self.dashboardCostPayloads(selection: selection)
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: usagePayloads,
            costPayloads: costPayloads,
            config: config,
            identityMode: identityMode,
            generatedAt: Date(),
            refreshInterval: refreshInterval,
            codexBarVersion: Self.currentVersion())

        return Self.serveJSON(snapshot)
    }

    private static func dashboardUsagePayloads(
        selection: ProviderSelection,
        config: CodexBarConfig) async -> [ProviderPayload]
    {
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: config,
                verbose: false)
        } catch {
            return [ProviderPayload(
                providerID: "cli",
                account: nil,
                version: nil,
                source: "cli",
                status: nil,
                usage: nil,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: Self.makeErrorPayload(error, kind: .config))]
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
            jsonOnly: true,
            includeAllCodexAccounts: false,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)

        var output = UsageCommandOutput()
        for provider in selection.asList {
            let status = await Self.fetchStatus(for: provider)
            let providerOutput = await ProviderInteractionContext.$current.withValue(.background) {
                await Self.fetchUsageOutputs(
                    provider: provider,
                    status: status,
                    tokenContext: tokenContext,
                    command: command)
            }
            output.merge(providerOutput)
        }
        return output.payload
    }

    private static func dashboardCostPayloads(selection: ProviderSelection) async -> [CostPayload] {
        let providers = Self.costProviders(from: selection)
        guard !providers.isEmpty else { return [] }

        let fetcher = CostUsageFetcher()
        var payload: [CostPayload] = []
        for provider in providers {
            do {
                let snapshot = try await fetcher.loadTokenSnapshot(provider: provider, forceRefresh: false)
                payload.append(Self.makeCostPayload(provider: provider, snapshot: snapshot, error: nil))
            } catch {
                payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
            }
        }
        return payload
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

    private static func serveJSON(_ payload: some Encodable, status: CLIHTTPStatus = .ok) -> CLILocalHTTPResponse {
        let json = Self.encodeJSON(payload, pretty: false) ?? "{}"
        return CLILocalHTTPResponse(status: status, body: Data(json.utf8))
    }

    private static func serveError(status: CLIHTTPStatus, message: String) -> CLILocalHTTPResponse {
        self.serveJSON(ServeErrorPayload(error: message), status: status)
    }
}
