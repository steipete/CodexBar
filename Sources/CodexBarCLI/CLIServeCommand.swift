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
}

enum CLIServeRoute: Equatable {
    case root
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
        case "/", "/index.html":
            return .root
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

private actor CLIServeResponseCache {
    private struct Entry {
        let expiresAt: Date
        let response: CLILocalHTTPResponse
    }

    private var entries: [String: Entry] = [:]

    func response(for key: String, now: Date) -> CLILocalHTTPResponse? {
        guard let entry = self.entries[key] else { return nil }
        guard entry.expiresAt > now else {
            self.entries[key] = nil
            return nil
        }
        return entry.response
    }

    func store(_ response: CLILocalHTTPResponse, for key: String, ttl: TimeInterval, now: Date) {
        guard ttl > 0, response.status == .ok else { return }
        self.entries[key] = Entry(expiresAt: now.addingTimeInterval(ttl), response: response)
    }
}

private enum CLIServeArgumentError: LocalizedError {
    case invalidPort
    case invalidRefreshInterval
    case invalidProvider(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "--port must be between 1 and 65535."
        case .invalidRefreshInterval:
            "--refresh-interval must be zero or greater."
        case let .invalidProvider(provider):
            "Unknown provider '\(provider)'."
        }
    }
}

extension CodexBarCLI {
    static func runServe(_ values: ParsedValues) async {
        let output = CLIOutputPreferences(format: .json, jsonOnly: true, pretty: false)
        let port = Self.decodeServePort(from: values)
        let refreshInterval = Self.decodeServeRefreshInterval(from: values)

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

        let config = Self.loadConfig(output: output)
        let cache = CLIServeResponseCache()
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: port) { request in
            await Self.handleServeRequest(
                request,
                config: config,
                cache: cache,
                refreshInterval: refreshInterval)
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

    private static func handleServeRequest(
        _ request: CLILocalHTTPRequest,
        config: CodexBarConfig,
        cache: CLIServeResponseCache,
        refreshInterval: TimeInterval) async -> CLILocalHTTPResponse
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
        case .root:
            return CLILocalHTTPResponse(
                status: .ok,
                body: Data(CLIWebUI.html.utf8),
                contentType: "text/html; charset=utf-8")
        case .health:
            return Self.serveJSON(ServeHealthPayload(status: "ok"))
        case let .usage(provider):
            return await Self.cachedServeResponse(
                key: "usage:\(provider ?? "")",
                cache: cache,
                refreshInterval: refreshInterval)
            {
                await Self.serveUsage(provider: provider, config: config)
            }
        case let .cost(provider):
            return await Self.cachedServeResponse(
                key: "cost:\(provider ?? "")",
                cache: cache,
                refreshInterval: refreshInterval)
            {
                await Self.serveCost(provider: provider, config: config)
            }
        }
    }

    private static func cachedServeResponse(
        key: String,
        cache: CLIServeResponseCache,
        refreshInterval: TimeInterval,
        makeResponse: () async -> CLILocalHTTPResponse) async -> CLILocalHTTPResponse
    {
        let now = Date()
        if let cached = await cache.response(for: key, now: now) {
            return cached
        }

        let response = await makeResponse()
        if Self.shouldCacheServeResponse(response) {
            await cache.store(response, for: key, ttl: refreshInterval, now: now)
        }
        return response
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
