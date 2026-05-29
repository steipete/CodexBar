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

        let config = Self.loadConfig(output: output)
        let cache = CLIServeResponseCache()
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: port) { request in
            await Self.handleServeRequest(
                request,
                config: config,
                cache: cache,
                refreshInterval: refreshInterval,
                requestTimeout: requestTimeout)
        }

        do {
            try await server.run {
                Self.writeStderr("CodexBar server listening on http://127.0.0.1:\(port)\n")
            }
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
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
        guard parsed >= 0 else { return nil }
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
        config: CodexBarConfig,
        cache: CLIServeResponseCache,
        refreshInterval: TimeInterval,
        requestTimeout: TimeInterval) async -> CLILocalHTTPResponse
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
        case let .usage(provider):
            return await Self.cachedServeResponse(
                key: "usage:\(provider ?? "")",
                cache: cache,
                refreshInterval: refreshInterval,
                requestTimeout: requestTimeout)
            {
                await Self.serveUsage(provider: provider, config: config)
            }
        case let .cost(provider):
            return await Self.cachedServeResponse(
                key: "cost:\(provider ?? "")",
                cache: cache,
                refreshInterval: refreshInterval,
                requestTimeout: requestTimeout)
            {
                await Self.serveCost(provider: provider, config: config)
            }
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
