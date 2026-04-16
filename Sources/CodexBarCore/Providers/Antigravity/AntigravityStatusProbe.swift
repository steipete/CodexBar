import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AntigravityModelQuota: Sendable {
    public let label: String
    public let modelId: String
    public let remainingFraction: Double?
    public let resetTime: Date?
    public let resetDescription: String?

    public init(
        label: String,
        modelId: String,
        remainingFraction: Double?,
        resetTime: Date?,
        resetDescription: String?)
    {
        self.label = label
        self.modelId = modelId
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double {
        guard let remainingFraction else { return 0 }
        return max(0, min(100, remainingFraction * 100))
    }
}

private enum AntigravityModelFamily {
    case claude
    case geminiPro
    case geminiFlash
    case unknown
}

private struct AntigravityNormalizedModel {
    let quota: AntigravityModelQuota
    let family: AntigravityModelFamily
    let selectionPriority: Int?
}

public struct AntigravityStatusSnapshot: Sendable {
    public let modelQuotas: [AntigravityModelQuota]
    public let accountEmail: String?
    public let accountPlan: String?

    public init(
        modelQuotas: [AntigravityModelQuota],
        accountEmail: String?,
        accountPlan: String?)
    {
        self.modelQuotas = modelQuotas
        self.accountEmail = accountEmail
        self.accountPlan = accountPlan
    }

    public func toUsageSnapshot() throws -> UsageSnapshot {
        guard !self.modelQuotas.isEmpty else {
            throw AntigravityStatusProbeError.parseFailed("No quota models available")
        }

        let normalized = Self.normalizedModels(self.modelQuotas)
        let primaryQuota = Self.representative(for: .claude, in: normalized)
        let secondaryQuota = Self.representative(for: .geminiPro, in: normalized)
        let tertiaryQuota = Self.representative(for: .geminiFlash, in: normalized)
        let fallbackQuota: AntigravityModelQuota? = if primaryQuota == nil, secondaryQuota == nil,
                                                       tertiaryQuota == nil
        {
            Self.fallbackRepresentative(in: normalized)
        } else {
            nil
        }

        let primary = (primaryQuota ?? fallbackQuota).map(Self.rateWindow(for:))
        let secondary = secondaryQuota.map(Self.rateWindow(for:))
        let tertiary = tertiaryQuota.map(Self.rateWindow(for:))

        let identity = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.accountPlan)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: Date(),
            identity: identity)
    }

    private static func rateWindow(for quota: AntigravityModelQuota) -> RateWindow {
        RateWindow(
            usedPercent: 100 - quota.remainingPercent,
            windowMinutes: nil,
            resetsAt: quota.resetTime,
            resetDescription: quota.resetDescription)
    }

    private static func normalizedModels(_ models: [AntigravityModelQuota]) -> [AntigravityNormalizedModel] {
        models.map { self.normalizeModel($0) }
    }

    private static func normalizeModel(_ quota: AntigravityModelQuota) -> AntigravityNormalizedModel {
        let modelId = quota.modelId.lowercased()
        let label = quota.label.lowercased()
        let family = Self.family(forModelID: modelId, label: label)

        let isLite = modelId.contains("lite") || label.contains("lite")
        let isAutocomplete = modelId.contains("autocomplete") || label.contains("autocomplete") || modelId
            .hasPrefix("tab_")
        let isLowPriorityGeminiPro = modelId.contains("pro-low")
            || (label.contains("pro") && label.contains("low"))

        let selectionPriority: Int? = switch family {
        case .claude:
            0
        case .geminiPro:
            if isLowPriorityGeminiPro {
                0
            } else if !isLite, !isAutocomplete {
                1
            } else {
                nil
            }
        case .geminiFlash:
            (!isLite && !isAutocomplete) ? 0 : nil
        case .unknown:
            nil
        }

        return AntigravityNormalizedModel(
            quota: quota,
            family: family,
            selectionPriority: selectionPriority)
    }

    private static func representative(
        for family: AntigravityModelFamily,
        in models: [AntigravityNormalizedModel]) -> AntigravityModelQuota?
    {
        let candidates = models.filter { $0.family == family && $0.selectionPriority != nil }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            let lhsPriority = lhs.selectionPriority ?? Int.max
            let rhsPriority = rhs.selectionPriority ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsHasRemainingFraction = lhs.quota.remainingFraction != nil
            let rhsHasRemainingFraction = rhs.quota.remainingFraction != nil
            if lhsHasRemainingFraction != rhsHasRemainingFraction {
                return lhsHasRemainingFraction && !rhsHasRemainingFraction
            }
            return lhs.quota.remainingPercent < rhs.quota.remainingPercent
        }?.quota
    }

    private static func fallbackRepresentative(in models: [AntigravityNormalizedModel]) -> AntigravityModelQuota? {
        guard !models.isEmpty else { return nil }
        return models.min { lhs, rhs in
            let lhsHasRemainingFraction = lhs.quota.remainingFraction != nil
            let rhsHasRemainingFraction = rhs.quota.remainingFraction != nil
            if lhsHasRemainingFraction != rhsHasRemainingFraction {
                return lhsHasRemainingFraction && !rhsHasRemainingFraction
            }
            if lhs.quota.remainingPercent != rhs.quota.remainingPercent {
                return lhs.quota.remainingPercent < rhs.quota.remainingPercent
            }
            return lhs.quota.label.localizedCaseInsensitiveCompare(rhs.quota.label) == .orderedAscending
        }?.quota
    }

    private static func family(forModelID modelId: String, label: String) -> AntigravityModelFamily {
        let modelIDFamily = Self.family(from: modelId)
        if modelIDFamily != .unknown {
            return modelIDFamily
        }
        return Self.family(from: label)
    }

    private static func family(from text: String) -> AntigravityModelFamily {
        if text.contains("claude") {
            return .claude
        }
        if text.contains("gemini"), text.contains("pro") {
            return .geminiPro
        }
        if text.contains("gemini"), text.contains("flash") {
            return .geminiFlash
        }
        return .unknown
    }
}

public struct AntigravityPlanInfoSummary: Sendable, Codable, Equatable {
    public let planName: String?
    public let planDisplayName: String?
    public let displayName: String?
    public let productName: String?
    public let planShortName: String?
}

public enum AntigravityStatusProbeError: LocalizedError, Sendable, Equatable {
    case notRunning
    case missingCSRFToken
    case portDetectionFailed(String)
    case apiError(String)
    case parseFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            "Antigravity language server not detected. Launch Antigravity and retry."
        case .missingCSRFToken:
            "Antigravity CSRF token not found. Restart Antigravity and retry."
        case let .portDetectionFailed(message):
            Self.portDetectionDescription(message)
        case let .apiError(message):
            Self.apiErrorDescription(message)
        case let .parseFailed(message):
            "Could not parse Antigravity quota: \(message)"
        case .timedOut:
            "Antigravity quota request timed out."
        }
    }

    private static func portDetectionDescription(_ message: String) -> String {
        switch message {
        case "lsof not available":
            "Antigravity port detection needs lsof. Install it, then retry."
        case "no listening ports found":
            "Antigravity is running but not exposing ports yet. Try again in a few seconds."
        default:
            "Antigravity port detection failed: \(message)"
        }
    }

    private static func apiErrorDescription(_ message: String) -> String {
        if message.contains("HTTP 401") || message.contains("HTTP 403") {
            return "Antigravity session expired. Restart Antigravity and retry."
        }
        return "Antigravity API error: \(message)"
    }
}

public struct AntigravityStatusProbe: Sendable {
    public var timeout: TimeInterval = 8.0

    private static let processName = "language_server_macos"
    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelConfigPath =
        "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let unleashPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public init(timeout: TimeInterval = 8.0) {
        self.timeout = timeout
    }

    public func fetch() async throws -> AntigravityStatusSnapshot {
        let processInfo = try await Self.detectProcessInfo(timeout: self.timeout)
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: self.timeout)
        let endpoint = try await Self.resolveWorkingEndpoint(
            candidateEndpoints: Self.connectionCandidates(
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: self.timeout)
        let context = RequestContext(
            endpoints: Self.requestEndpoints(
                resolvedEndpoint: endpoint,
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: self.timeout)

        do {
            return try await Self.makeParsedRequest(
                payload: RequestPayload(
                    path: Self.getUserStatusPath,
                    body: Self.defaultRequestBody()),
                context: context,
                parse: Self.parseUserStatusResponse)
        } catch {
            return try await Self.makeParsedRequest(
                payload: RequestPayload(
                    path: Self.commandModelConfigPath,
                    body: Self.defaultRequestBody()),
                context: context,
                parse: Self.parseCommandModelResponse)
        }
    }

    public func fetchPlanInfoSummary() async throws -> AntigravityPlanInfoSummary? {
        let processInfo = try await Self.detectProcessInfo(timeout: self.timeout)
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: self.timeout)
        let endpoint = try await Self.resolveWorkingEndpoint(
            candidateEndpoints: Self.connectionCandidates(
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: self.timeout)
        return try await Self.makeParsedRequest(
            payload: RequestPayload(
                path: Self.getUserStatusPath,
                body: Self.defaultRequestBody()),
            context: RequestContext(
                endpoints: Self.requestEndpoints(
                    resolvedEndpoint: endpoint,
                    listeningPorts: ports,
                    languageServerCSRFToken: processInfo.csrfToken,
                    extensionServerPort: processInfo.extensionPort,
                    extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
                timeout: self.timeout),
            parse: Self.parsePlanInfoSummary)
    }

    public static func isRunning(timeout: TimeInterval = 4.0) async -> Bool {
        await (try? self.detectProcessInfo(timeout: timeout)) != nil
    }

    public static func detectVersion(timeout: TimeInterval = 4.0) async -> String? {
        let running = await Self.isRunning(timeout: timeout)
        return running ? "running" : nil
    }

    // MARK: - Parsing

    public static func parseUserStatusResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(UserStatusResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        guard let userStatus = response.userStatus else {
            throw AntigravityStatusProbeError.parseFailed("Missing userStatus")
        }

        let modelConfigs = userStatus.cascadeModelConfigData?.clientModelConfigs ?? []
        let models = modelConfigs.compactMap(Self.quotaFromConfig(_:))
        let email = userStatus.email
        // Prefer userTier.name (actual subscription tier) over planInfo (shows "Pro" for Ultra users)
        let planName = userStatus.userTier?.preferredName ?? userStatus.planStatus?.planInfo?.preferredName

        return AntigravityStatusSnapshot(
            modelQuotas: models,
            accountEmail: email,
            accountPlan: planName)
    }

    static func parsePlanInfoSummary(_ data: Data) throws -> AntigravityPlanInfoSummary? {
        let decoder = JSONDecoder()
        let response = try decoder.decode(UserStatusResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        guard let userStatus = response.userStatus else {
            throw AntigravityStatusProbeError.parseFailed("Missing userStatus")
        }
        guard let planInfo = userStatus.planStatus?.planInfo else { return nil }
        return AntigravityPlanInfoSummary(
            planName: planInfo.planName,
            planDisplayName: planInfo.planDisplayName,
            displayName: planInfo.displayName,
            productName: planInfo.productName,
            planShortName: planInfo.planShortName)
    }

    static func parseCommandModelResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(CommandModelConfigResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        let modelConfigs = response.clientModelConfigs ?? []
        let models = modelConfigs.compactMap(Self.quotaFromConfig(_:))
        return AntigravityStatusSnapshot(modelQuotas: models, accountEmail: nil, accountPlan: nil)
    }

    private static func quotaFromConfig(_ config: ModelConfig) -> AntigravityModelQuota? {
        guard let quota = config.quotaInfo else { return nil }
        let reset = quota.resetTime.flatMap { Self.parseDate($0) }
        return AntigravityModelQuota(
            label: config.label,
            modelId: config.modelOrAlias.model,
            remainingFraction: quota.remainingFraction,
            resetTime: reset,
            resetDescription: nil)
    }

    private static func invalidCode(_ code: CodeValue?) -> String? {
        guard let code else { return nil }
        if code.isOK { return nil }
        return "\(code.rawValue)"
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    // MARK: - Port detection

    private struct ProcessInfoResult {
        let pid: Int
        let extensionPort: Int?
        let extensionServerCSRFToken: String?
        let csrfToken: String
        let commandLine: String
    }

    struct AntigravityConnectionEndpoint: Equatable {
        enum Source: String {
            case languageServer = "language-server"
            case extensionServer = "extension-server"
        }

        let scheme: String
        let port: Int
        let csrfToken: String
        let source: Source

        func matchesRequestTarget(_ other: Self) -> Bool {
            self.scheme == other.scheme && self.port == other.port && self.csrfToken == other.csrfToken
        }
    }

    private static func detectProcessInfo(timeout: TimeInterval) async throws -> ProcessInfoResult {
        let env = ProcessInfo.processInfo.environment
        let result = try await SubprocessRunner.run(
            binary: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            environment: env,
            timeout: timeout,
            label: "antigravity-ps")

        let lines = result.stdout.split(separator: "\n")
        var sawAntigravity = false
        for line in lines {
            let text = String(line)
            guard let match = Self.matchProcessLine(text) else { continue }
            let lower = match.command.lowercased()
            guard lower.contains(Self.processName) else { continue }
            guard Self.isAntigravityCommandLine(lower) else { continue }
            sawAntigravity = true
            guard let token = Self.extractFlag("--csrf_token", from: match.command) else { continue }
            let port = Self.extractPort("--extension_server_port", from: match.command)
            let extensionServerCSRFToken = Self.extractFlag("--extension_server_csrf_token", from: match.command)
            return ProcessInfoResult(
                pid: match.pid,
                extensionPort: port,
                extensionServerCSRFToken: extensionServerCSRFToken,
                csrfToken: token,
                commandLine: match.command)
        }

        if sawAntigravity {
            throw AntigravityStatusProbeError.missingCSRFToken
        }
        throw AntigravityStatusProbeError.notRunning
    }

    private struct ProcessLineMatch {
        let pid: Int
        let command: String
    }

    private static func matchProcessLine(_ line: String) -> ProcessLineMatch? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
        return ProcessLineMatch(pid: pid, command: String(parts[1]))
    }

    private static func isAntigravityCommandLine(_ command: String) -> Bool {
        if command.contains("--app_data_dir") && command.contains("antigravity") { return true }
        if command.contains("/antigravity/") || command.contains("\\antigravity\\") { return true }
        return false
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[tokenRange])
    }

    private static func extractPort(_ flag: String, from command: String) -> Int? {
        guard let raw = extractFlag(flag, from: command) else { return nil }
        return Int(raw)
    }

    private static func listeningPorts(pid: Int, timeout: TimeInterval) async throws -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })

        guard let lsof else {
            throw AntigravityStatusProbeError.portDetectionFailed("lsof not available")
        }

        let env = ProcessInfo.processInfo.environment
        let result = try await SubprocessRunner.run(
            binary: lsof,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            environment: env,
            timeout: timeout,
            label: "antigravity-lsof")

        let ports = Self.parseListeningPorts(result.stdout)
        if ports.isEmpty {
            throw AntigravityStatusProbeError.portDetectionFailed("no listening ports found")
        }
        return ports
    }

    private static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: 1), in: output),
                  let value = Int(output[range]) else { return }
            ports.insert(value)
        }
        return ports.sorted()
    }

    static func connectionCandidates(
        listeningPorts: [Int],
        languageServerCSRFToken: String,
        extensionServerPort: Int?,
        extensionServerCSRFToken: String?) -> [AntigravityConnectionEndpoint]
    {
        var endpoints = Self.languageServerEndpoints(
            listeningPorts: listeningPorts,
            languageServerCSRFToken: languageServerCSRFToken)

        for endpoint in Self.extensionServerEndpoints(
            extensionServerPort: extensionServerPort,
            languageServerCSRFToken: languageServerCSRFToken,
            extensionServerCSRFToken: extensionServerCSRFToken)
        {
            guard !endpoints.contains(where: { $0.matchesRequestTarget(endpoint) }) else { continue }
            endpoints.append(endpoint)
        }

        return endpoints
    }

    static func requestEndpoints(
        resolvedEndpoint: AntigravityConnectionEndpoint,
        listeningPorts: [Int],
        languageServerCSRFToken: String,
        extensionServerPort: Int?,
        extensionServerCSRFToken: String?) -> [AntigravityConnectionEndpoint]
    {
        var endpoints = [resolvedEndpoint]

        if resolvedEndpoint.source == .extensionServer {
            Self.appendUniqueRequestTargets(
                from: Self.extensionServerEndpoints(
                    extensionServerPort: extensionServerPort,
                    languageServerCSRFToken: languageServerCSRFToken,
                    extensionServerCSRFToken: extensionServerCSRFToken),
                to: &endpoints)
            Self.appendUniqueRequestTargets(
                from: Self.languageServerEndpoints(
                    listeningPorts: listeningPorts,
                    languageServerCSRFToken: languageServerCSRFToken),
                to: &endpoints)
        } else {
            Self.appendUniqueRequestTargets(
                from: Self.languageServerEndpoints(
                    listeningPorts: listeningPorts,
                    languageServerCSRFToken: languageServerCSRFToken),
                to: &endpoints)
            Self.appendUniqueRequestTargets(
                from: Self.extensionServerEndpoints(
                    extensionServerPort: extensionServerPort,
                    languageServerCSRFToken: languageServerCSRFToken,
                    extensionServerCSRFToken: extensionServerCSRFToken),
                to: &endpoints)
        }

        return endpoints
    }

    private static func languageServerEndpoints(
        listeningPorts: [Int],
        languageServerCSRFToken: String) -> [AntigravityConnectionEndpoint]
    {
        listeningPorts.map {
            AntigravityConnectionEndpoint(
                scheme: "https",
                port: $0,
                csrfToken: languageServerCSRFToken,
                source: .languageServer)
        }
    }

    private static func extensionServerEndpoints(
        extensionServerPort: Int?,
        languageServerCSRFToken: String,
        extensionServerCSRFToken: String?) -> [AntigravityConnectionEndpoint]
    {
        guard let extensionServerPort else { return [] }

        var endpoints: [AntigravityConnectionEndpoint] = []
        if let extensionServerCSRFToken {
            endpoints.append(
                AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: extensionServerPort,
                    csrfToken: extensionServerCSRFToken,
                    source: .extensionServer))
        }

        if extensionServerCSRFToken != languageServerCSRFToken {
            endpoints.append(
                AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: extensionServerPort,
                    csrfToken: languageServerCSRFToken,
                    source: .extensionServer))
        }

        return endpoints
    }

    private static func appendUniqueRequestTargets(
        from candidates: [AntigravityConnectionEndpoint],
        to endpoints: inout [AntigravityConnectionEndpoint])
    {
        for endpoint in candidates {
            guard !endpoints.contains(where: { $0.matchesRequestTarget(endpoint) }) else { continue }
            endpoints.append(endpoint)
        }
    }

    static func resolveWorkingEndpoint(
        candidateEndpoints: [AntigravityConnectionEndpoint],
        timeout: TimeInterval,
        testConnectivity: @escaping @Sendable (AntigravityConnectionEndpoint, TimeInterval) async -> Bool = Self
            .testEndpointConnectivity) async throws -> AntigravityConnectionEndpoint
    {
        for endpoint in candidateEndpoints {
            let ok = await testConnectivity(endpoint, timeout)
            if ok { return endpoint }
        }
        if let fallback = fallbackProbeEndpoint(candidateEndpoints) {
            self.log.debug("Port probe fell back to best-effort endpoint", metadata: [
                "source": fallback.source.rawValue,
                "scheme": fallback.scheme,
                "port": "\(fallback.port)",
            ])
            return fallback
        }
        throw AntigravityStatusProbeError.portDetectionFailed("no working API port found")
    }

    static func fallbackProbePort(ports: [Int], extensionPort: Int?) -> Int? {
        if let nonExtension = ports.first(where: { $0 != extensionPort }) {
            return nonExtension
        }
        if let extensionPort {
            return extensionPort
        }
        return ports.first
    }

    static func isReachableProbeError(_ error: Error) -> Bool {
        guard case let AntigravityStatusProbeError.apiError(message) = error else { return false }
        return message.hasPrefix("HTTP ")
    }

    private static func fallbackProbeEndpoint(
        _ endpoints: [AntigravityConnectionEndpoint]) -> AntigravityConnectionEndpoint?
    {
        if let languageServerEndpoint = endpoints.first(where: { $0.source == .languageServer }) {
            return languageServerEndpoint
        }
        return endpoints.first
    }

    private static func testEndpointConnectivity(
        _ endpoint: AntigravityConnectionEndpoint,
        timeout: TimeInterval) async -> Bool
    {
        do {
            _ = try await self.makeRequest(
                payload: RequestPayload(
                    path: self.unleashPath,
                    body: self.unleashRequestBody()),
                context: RequestContext(endpoints: [endpoint], timeout: timeout))
            return true
        } catch {
            if self.isReachableProbeError(error) {
                self.log.debug("Port probe received HTTP response; treating endpoint as reachable", metadata: [
                    "source": endpoint.source.rawValue,
                    "scheme": endpoint.scheme,
                    "port": "\(endpoint.port)",
                    "error": error.localizedDescription,
                ])
                return true
            }
            self.log.debug("Port probe failed", metadata: [
                "source": endpoint.source.rawValue,
                "scheme": endpoint.scheme,
                "port": "\(endpoint.port)",
                "error": error.localizedDescription,
            ])
            return false
        }
    }

    // MARK: - HTTP

    struct RequestPayload {
        let path: String
        let body: [String: Any]
    }

    struct RequestContext {
        let endpoints: [AntigravityConnectionEndpoint]
        let timeout: TimeInterval
    }

    private static func defaultRequestBody() -> [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
    }

    private static func unleashRequestBody() -> [String: Any] {
        [
            "context": [
                "properties": [
                    "devMode": "false",
                    "extensionVersion": "unknown",
                    "hasAnthropicModelAccess": "true",
                    "ide": "antigravity",
                    "ideVersion": "unknown",
                    "installationId": "codexbar",
                    "language": "UNSPECIFIED",
                    "os": "macos",
                    "requestedModelId": "MODEL_UNSPECIFIED",
                ],
            ],
        ]
    }

    private static func makeRequest(
        payload: RequestPayload,
        context: RequestContext) async throws -> Data
    {
        try await self.sendRequest(payload: payload, context: context)
    }

    static func makeParsedRequest<T>(
        payload: RequestPayload,
        context: RequestContext,
        send: @escaping @Sendable (RequestPayload, AntigravityConnectionEndpoint, TimeInterval) async throws -> Data =
            sendRequest,
        parse: @escaping @Sendable (Data) throws -> T) async throws -> T
    {
        var lastError: Error?

        for endpoint in context.endpoints {
            do {
                let data = try await send(payload, endpoint, context.timeout)
                return try parse(data)
            } catch {
                lastError = error
                Self.log.debug("Antigravity request/parse attempt failed", metadata: [
                    "path": payload.path,
                    "source": endpoint.source.rawValue,
                    "scheme": endpoint.scheme,
                    "port": "\(endpoint.port)",
                    "error": error.localizedDescription,
                ])
            }
        }

        throw lastError ?? AntigravityStatusProbeError.apiError("Invalid response")
    }

    private static func sendRequest(
        payload: RequestPayload,
        context: RequestContext) async throws -> Data
    {
        var lastError: Error?

        for endpoint in context.endpoints {
            do {
                return try await Self.sendRequest(payload: payload, endpoint: endpoint, timeout: context.timeout)
            } catch {
                lastError = error
                Self.log.debug("Antigravity request attempt failed", metadata: [
                    "path": payload.path,
                    "source": endpoint.source.rawValue,
                    "scheme": endpoint.scheme,
                    "port": "\(endpoint.port)",
                    "error": error.localizedDescription,
                ])
            }
        }

        throw lastError ?? AntigravityStatusProbeError.apiError("Invalid URL")
    }

    private static func sendRequest(
        payload: RequestPayload,
        endpoint: AntigravityConnectionEndpoint,
        timeout: TimeInterval) async throws -> Data
    {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(payload.path)") else {
            throw AntigravityStatusProbeError.apiError("Invalid URL")
        }

        let body = try JSONSerialization.data(withJSONObject: payload.body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        #if !os(Linux)
        config.waitsForConnectivity = false
        #endif

        let delegate = LocalhostSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await delegate.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityStatusProbeError.apiError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityStatusProbeError.apiError("HTTP \(http.statusCode): \(message)")
        }
        return data
    }
}

enum LocalhostTrustPolicy {
    static func shouldAcceptServerTrust(
        host: String,
        authenticationMethod: String,
        hasServerTrust: Bool) -> Bool
    {
        #if !os(Linux)
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else { return false }
        #endif
        let normalizedHost = host.lowercased()
        guard normalizedHost == "127.0.0.1" || normalizedHost == "localhost" else { return false }
        return hasServerTrust
    }
}

private final class LocalhostSessionDelegate: NSObject {
    func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let state = LocalhostSessionTaskState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: AntigravityStatusProbeError.apiError("Invalid response"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                state.setTask(task)
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }

    private func challengeResult(_ challenge: URLAuthenticationChallenge) -> (
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?)
    {
        #if os(Linux)
        return (.performDefaultHandling, nil)
        #else
        let protectionSpace = challenge.protectionSpace
        let trust = protectionSpace.serverTrust
        guard LocalhostTrustPolicy.shouldAcceptServerTrust(
            host: protectionSpace.host,
            authenticationMethod: protectionSpace.authenticationMethod,
            hasServerTrust: trust != nil),
            let trust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
        #endif
    }
}

extension LocalhostSessionDelegate: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        self.challengeResult(challenge)
    }
}

extension LocalhostSessionDelegate: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        self.challengeResult(challenge)
    }
}

private final class LocalhostSessionTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func setTask(_ task: URLSessionDataTask) {
        self.lock.lock()
        self.task = task
        let shouldCancel = self.isCancelled
        self.lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        self.lock.lock()
        self.isCancelled = true
        let task = self.task
        self.lock.unlock()
        task?.cancel()
    }
}

private struct UserStatusResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let userStatus: UserStatus?
}

private struct CommandModelConfigResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let clientModelConfigs: [ModelConfig]?
}

private struct UserStatus: Decodable {
    let email: String?
    let planStatus: PlanStatus?
    let cascadeModelConfigData: ModelConfigData?
    let userTier: UserTier?
}

private struct UserTier: Decodable {
    let id: String?
    let name: String?
    let description: String?

    var preferredName: String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return value.isEmpty ? nil : value
    }
}

private struct PlanStatus: Decodable {
    let planInfo: PlanInfo?
}

private struct PlanInfo: Decodable {
    let planName: String?
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planShortName: String?

    var preferredName: String? {
        let candidates = [
            planDisplayName,
            displayName,
            productName,
            planName,
            planShortName,
        ]
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if !value.isEmpty { return value }
        }
        return nil
    }
}

private struct ModelConfigData: Decodable {
    let clientModelConfigs: [ModelConfig]?
}

private struct ModelConfig: Decodable {
    let label: String
    let modelOrAlias: ModelAlias
    let quotaInfo: QuotaInfo?
}

private struct ModelAlias: Decodable {
    let model: String
}

private struct QuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

private enum CodeValue: Decodable {
    case int(Int)
    case string(String)

    var isOK: Bool {
        switch self {
        case let .int(value):
            return value == 0
        case let .string(value):
            let lower = value.lowercased()
            return lower == "ok" || lower == "success" || value == "0"
        }
    }

    var rawValue: String {
        switch self {
        case let .int(value): "\(value)"
        case let .string(value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported code type")
    }
}
