import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WayfinderUsageError: LocalizedError, Equatable, Sendable {
    case gatewayUnreachable
    case apiError(Int)
    case parseFailed(String)
    case unexpectedRedirect

    public var errorDescription: String? {
        switch self {
        case .gatewayUnreachable:
            "Could not reach the Wayfinder gateway. Start it with `wayfinder-router serve` " +
                "(default http://127.0.0.1:8088) or fix the Gateway URL in Settings."
        case let .apiError(statusCode):
            "Wayfinder gateway returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse Wayfinder gateway response: \(message)"
        case .unexpectedRedirect:
            "Wayfinder gateway request was redirected to a different origin."
        }
    }
}

public struct WayfinderUsageSnapshot: Codable, Sendable, Equatable {
    public struct RouteSummary: Codable, Sendable, Equatable {
        public let name: String
        public let requests: Int
        public let saved: Double
        public let tokens: Int

        public init(name: String, requests: Int, saved: Double, tokens: Int) {
            self.name = name
            self.requests = requests
            self.saved = saved
            self.tokens = tokens
        }
    }

    public let gatewayStatus: String
    public let offline: Bool
    public let dryRun: Bool
    public let missingKeys: [String]
    public let modelCount: Int
    public let requests: Int
    public let tokens: Int
    public let realized: Double
    public let baseline: Double
    public let saved: Double
    public let savedPct: Double
    public let priced: Bool
    public let routes: [RouteSummary]
    public let avgDecisionMs: Double?
    public let updatedAt: Date

    public init(
        gatewayStatus: String,
        offline: Bool,
        dryRun: Bool,
        missingKeys: [String],
        modelCount: Int,
        requests: Int,
        tokens: Int,
        realized: Double,
        baseline: Double,
        saved: Double,
        savedPct: Double,
        priced: Bool,
        routes: [RouteSummary],
        avgDecisionMs: Double?,
        updatedAt: Date)
    {
        self.gatewayStatus = gatewayStatus
        self.offline = offline
        self.dryRun = dryRun
        self.missingKeys = missingKeys
        self.modelCount = modelCount
        self.requests = requests
        self.tokens = tokens
        self.realized = realized
        self.baseline = baseline
        self.saved = saved
        self.savedPct = savedPct
        self.priced = priced
        self.routes = routes
        self.avgDecisionMs = avgDecisionMs
        self.updatedAt = updatedAt
    }

    public var statusLabel: String {
        if self.offline {
            return "Offline mode"
        }
        if self.dryRun {
            return "Dry run"
        }
        if self.gatewayStatus == "degraded" {
            let count = self.missingKeys.count
            guard count > 0 else { return "Degraded" }
            return count == 1 ? "Degraded — 1 key missing" : "Degraded — \(count) keys missing"
        }
        return "Local gateway"
    }

    public var modelCountLabel: String {
        self.modelCount == 1 ? "1 model" : "\(self.modelCount) models"
    }

    public var gatewaySummary: String {
        var summary = "\(self.gatewayStatus) · \(self.modelCountLabel)"
        if self.offline {
            summary += " · offline"
        }
        if self.dryRun {
            summary += " · dry run"
        }
        return summary
    }

    public var displayLines: [String] {
        var lines = ["Gateway: \(self.gatewaySummary)"]
        if let routed = self.routedSummary {
            lines.append("Routed: \(routed)")
        }
        if let saved = self.savedSummary {
            lines.append("Saved: \(saved)")
        }
        if let avgDecision = self.avgDecisionSummary {
            lines.append("Avg decision: \(avgDecision)")
        }
        return lines
    }

    /// "local: 10 · cloud: 4" — the gateway's own configured route names, not a guessed
    /// local/cloud split: `/router/models` has no field asserting which tier is "local", and
    /// route names are whatever the user named their endpoints in the Wayfinder config.
    /// nil until the gateway has routed anything in the period.
    public var routedSummary: String? {
        guard self.requests > 0 else { return nil }
        let mix = self.routes.prefix(5)
            .map { "\($0.name): \(UsageFormatter.tokenCountString($0.requests))" }
            .joined(separator: " · ")
        return mix.isEmpty ? nil : mix
    }

    /// "$4.12 · 38.2% vs highest-cost route" when priced; percent-only otherwise.
    /// Savings in relative (unpriced) units are never rendered as dollars.
    public var savedSummary: String? {
        guard self.requests > 0, self.saved > 0 else { return nil }
        let pct = "\(Self.percentText(self.savedPct))% vs highest-cost route"
        guard self.priced else { return pct }
        let amount = self.saved < 0.01
            ? "<$0.01"
            : UsageFormatter.currencyString(self.saved, currencyCode: "USD")
        return "\(amount) · \(pct)"
    }

    public var avgDecisionSummary: String? {
        guard let ms = self.avgDecisionMs else { return nil }
        return String(format: "%.1f ms", ms)
    }

    private static func percentText(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // No rate window and no providerCost: the gateway has no quota semantics, and
        // sub-cent realized spend would render as a meaningless cost meter. Savings are
        // surfaced through the dedicated Wayfinder lines instead.
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            wayfinderUsage: self,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .wayfinder,
                accountEmail: nil,
                accountOrganization: "\(self.modelCountLabel) · local gateway",
                loginMethod: self.statusLabel),
            dataConfidence: .exact)
    }
}

private struct WayfinderHealthResponse: Decodable {
    let status: String
    let offline: Bool
    let missingKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case status
        case offline
        case missingKeys = "missing_keys"
    }
}

private struct WayfinderModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
    let dryRun: Bool

    enum CodingKeys: String, CodingKey {
        case models
        case dryRun = "dry_run"
    }
}

private struct WayfinderSavingsResponse: Decodable {
    struct RouteBucket: Decodable {
        let requests: Int
        let saved: Double
        let tokens: Int
    }

    let priced: Bool
    let requests: Int
    let tokens: Int
    let realized: Double
    let baseline: Double
    let saved: Double
    let savedPct: Double
    let byRoute: [String: RouteBucket]

    enum CodingKeys: String, CodingKey {
        case priced
        case requests
        case tokens
        case realized
        case baseline
        case saved
        case savedPct = "saved_pct"
        case byRoute = "by_route"
    }
}

public enum WayfinderUsageFetcher {
    /// Savings window mirrored in the "Last 30 days" period label of `toUsageSnapshot()`.
    static let savingsPeriod = "30d"
    static let decisionLatencyMetric = "wayfinder_router_decision_latency_seconds"

    public static func fetchUsage(
        baseURL: URL,
        updatedAt: Date = Date()) async throws -> WayfinderUsageSnapshot
    {
        try await self.fetchUsage(
            baseURL: baseURL,
            transport: self.isolatedTransport,
            updatedAt: updatedAt)
    }

    public static func fetchUsage(
        baseURL: URL,
        transport: any ProviderHTTPTransport,
        updatedAt: Date = Date()) async throws -> WayfinderUsageSnapshot
    {
        let healthData = try await self.get(path: "healthz", baseURL: baseURL, transport: transport)
        let modelsData = try await self.get(path: "router/models", baseURL: baseURL, transport: transport)
        let savingsData = try await self.get(
            path: "v1/savings",
            queryItems: [URLQueryItem(name: "period", value: self.savingsPeriod)],
            baseURL: baseURL,
            transport: transport)
        // Latency is best-effort: the snapshot must never fail because /metrics is unavailable.
        // Cancellation is control flow, though, and must still stop the whole refresh.
        let metricsData: Data?
        do {
            metricsData = try await self.get(path: "metrics", baseURL: baseURL, transport: transport)
        } catch {
            if self.isCancellation(error) {
                throw CancellationError()
            }
            metricsData = nil
        }

        return try self.makeSnapshot(
            healthData: healthData,
            modelsData: modelsData,
            savingsData: savingsData,
            metricsText: metricsData.flatMap { String(data: $0, encoding: .utf8) },
            updatedAt: updatedAt)
    }

    public static func _makeSnapshotForTesting(
        healthData: Data,
        modelsData: Data,
        savingsData: Data,
        metricsText: String?,
        updatedAt: Date) throws -> WayfinderUsageSnapshot
    {
        try self.makeSnapshot(
            healthData: healthData,
            modelsData: modelsData,
            savingsData: savingsData,
            metricsText: metricsText,
            updatedAt: updatedAt)
    }

    public static func _averageDecisionMillisecondsForTesting(_ text: String) -> Double? {
        self.averageDecisionMilliseconds(fromPrometheusText: text)
    }

    private static func makeSnapshot(
        healthData: Data,
        modelsData: Data,
        savingsData: Data,
        metricsText: String?,
        updatedAt: Date) throws -> WayfinderUsageSnapshot
    {
        let health = try self.parseHealth(data: healthData)
        let models = try self.parseModels(data: modelsData)
        let savings = try self.parseSavings(data: savingsData)
        let avgDecisionMs = metricsText.flatMap { self.averageDecisionMilliseconds(fromPrometheusText: $0) }

        return WayfinderUsageSnapshot(
            gatewayStatus: health.status,
            offline: health.offline,
            dryRun: models.dryRun,
            missingKeys: health.missingKeys ?? [],
            modelCount: models.models.count,
            requests: savings.requests,
            tokens: savings.tokens,
            realized: savings.realized,
            baseline: savings.baseline,
            saved: savings.saved,
            savedPct: savings.savedPct,
            priced: savings.priced,
            routes: savings.byRoute.map { name, bucket in
                WayfinderUsageSnapshot.RouteSummary(
                    name: name,
                    requests: bucket.requests,
                    saved: bucket.saved,
                    tokens: bucket.tokens)
            }.sorted {
                if $0.requests != $1.requests {
                    return $0.requests > $1.requests
                }
                return $0.name < $1.name
            },
            avgDecisionMs: avgDecisionMs,
            updatedAt: updatedAt)
    }

    public static func _endpointURLForTesting(baseURL: URL, path: String) -> URL {
        self.endpointURL(baseURL: baseURL, path: path, queryItems: [])
    }

    private static func get(
        path: String,
        queryItems: [URLQueryItem] = [],
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        var request = URLRequest(url: self.endpointURL(baseURL: baseURL, path: path, queryItems: queryItems))
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            if self.isCancellation(error) {
                throw CancellationError()
            }
            throw WayfinderUsageError.gatewayUnreachable
        }
        try self.validateSameOrigin(response: response, request: request)
        guard (200..<300).contains(response.statusCode) else {
            throw WayfinderUsageError.apiError(response.statusCode)
        }
        return response.data
    }

    private static func endpointURL(baseURL: URL, path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/\(path)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? baseURL
    }

    private static func validateSameOrigin(response: ProviderHTTPResponse, request: URLRequest) throws {
        guard let requestURL = request.url,
              let responseURL = response.response.url,
              requestURL.scheme?.lowercased() == responseURL.scheme?.lowercased(),
              requestURL.host?.lowercased() == responseURL.host?.lowercased(),
              self.effectivePort(for: requestURL) == self.effectivePort(for: responseURL)
        else {
            throw WayfinderUsageError.unexpectedRedirect
        }
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static let isolatedTransport: any ProviderHTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private static func parseHealth(data: Data) throws -> WayfinderHealthResponse {
        try self.decode(WayfinderHealthResponse.self, from: data, endpoint: "/healthz")
    }

    private static func parseModels(data: Data) throws -> WayfinderModelsResponse {
        try self.decode(WayfinderModelsResponse.self, from: data, endpoint: "/router/models")
    }

    private static func parseSavings(data: Data) throws -> WayfinderSavingsResponse {
        try self.decode(WayfinderSavingsResponse.self, from: data, endpoint: "/v1/savings")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WayfinderUsageError.parseFailed("\(endpoint): \(error.localizedDescription)")
        }
    }

    private static func averageDecisionMilliseconds(fromPrometheusText text: String) -> Double? {
        var sum: Double?
        var count: Double?
        for line in text.split(separator: "\n") {
            if let value = self.metricValue(line: line, name: "\(self.decisionLatencyMetric)_sum") {
                sum = value
            } else if let value = self.metricValue(line: line, name: "\(self.decisionLatencyMetric)_count") {
                count = value
            }
        }
        guard let sum, let count, count > 0 else { return nil }
        return sum / count * 1000
    }

    private static func metricValue(line: Substring, name: String) -> Double? {
        guard line.hasPrefix(name) else { return nil }
        let rest = line.dropFirst(name.count)
        guard let first = rest.first, first == " " || first == "{" else { return nil }
        guard let valueToken = rest.split(separator: " ").last else { return nil }
        return Double(valueToken)
    }
}
