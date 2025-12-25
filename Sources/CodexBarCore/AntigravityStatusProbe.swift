import Foundation
#if canImport(os.log)
import os.log
#endif

public struct AntigravityModelQuota: Sendable {
    public let label: String
    public let modelId: String
    public let remainingFraction: Double?
    public let resetTime: Date?
    public let resetDescription: String?

    public var remainingPercent: Double {
        guard let remainingFraction else { return 0 }
        return max(0, min(100, remainingFraction * 100))
    }
}

public struct AntigravityStatusSnapshot: Sendable {
    public let modelQuotas: [AntigravityModelQuota]
    public let accountEmail: String?
    public let accountPlan: String?

    public func toUsageSnapshot() throws -> UsageSnapshot {
        let ordered = Self.selectModels(self.modelQuotas)
        guard let primaryQuota = ordered.first else {
            throw AntigravityStatusProbeError.parseFailed("No quota models available")
        }

        let primary = Self.rateWindow(for: primaryQuota)
        let secondary = ordered.count > 1 ? Self.rateWindow(for: ordered[1]) : nil
        let tertiary = ordered.count > 2 ? Self.rateWindow(for: ordered[2]) : nil

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: Date(),
            accountEmail: self.accountEmail,
            loginMethod: self.accountPlan)
    }

    private static func rateWindow(for quota: AntigravityModelQuota) -> RateWindow {
        RateWindow(
            usedPercent: 100 - quota.remainingPercent,
            windowMinutes: nil,
            resetsAt: quota.resetTime,
            resetDescription: quota.resetDescription)
    }

    private static func selectModels(_ models: [AntigravityModelQuota]) -> [AntigravityModelQuota] {
        var ordered: [AntigravityModelQuota] = []
        if let claude = models.first(where: { Self.isClaudeWithoutThinking($0.label) }) {
            ordered.append(claude)
        }
        if let pro = models.first(where: { Self.isGeminiProLow($0.label) }),
           !ordered.contains(where: { $0.label == pro.label })
        {
            ordered.append(pro)
        }
        if let flash = models.first(where: { Self.isGeminiFlash($0.label) }),
           !ordered.contains(where: { $0.label == flash.label })
        {
            ordered.append(flash)
        }
        if ordered.isEmpty {
            ordered.append(contentsOf: models.sorted(by: { $0.remainingPercent < $1.remainingPercent }))
        }
        return ordered
    }

    private static func isClaudeWithoutThinking(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("claude") && !lower.contains("thinking")
    }

    private static func isGeminiProLow(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("pro") && lower.contains("low")
    }

    private static func isGeminiFlash(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("gemini") && lower.contains("flash")
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
    #if canImport(os.log)
    private static let log = Logger(subsystem: "com.steipete.codexbar", category: "antigravity")
    #endif

    public init(timeout: TimeInterval = 8.0) {
        self.timeout = timeout
    }

    public func fetch() async throws -> AntigravityStatusSnapshot {
        let processInfo = try await Self.detectProcessInfo(timeout: self.timeout)
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: self.timeout)
        let connectPort = try await Self.findWorkingPort(
            ports: ports,
            csrfToken: processInfo.csrfToken,
            timeout: self.timeout)
        let context = RequestContext(
            httpsPort: connectPort,
            httpPort: processInfo.extensionPort,
            csrfToken: processInfo.csrfToken,
            timeout: self.timeout)

        do {
            let response = try await Self.makeRequest(
                payload: RequestPayload(
                    path: Self.getUserStatusPath,
                    body: Self.defaultRequestBody()),
                context: context)
            return try Self.parseUserStatusResponse(response)
        } catch {
            let response = try await Self.makeRequest(
                payload: RequestPayload(
                    path: Self.commandModelConfigPath,
                    body: Self.defaultRequestBody()),
                context: context)
            return try Self.parseCommandModelResponse(response)
        }
    }

    public func fetchPlanInfoSummary() async throws -> AntigravityPlanInfoSummary? {
        let processInfo = try await Self.detectProcessInfo(timeout: self.timeout)
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: self.timeout)
        let connectPort = try await Self.findWorkingPort(
            ports: ports,
            csrfToken: processInfo.csrfToken,
            timeout: self.timeout)
        let response = try await Self.makeRequest(
            payload: RequestPayload(
                path: Self.getUserStatusPath,
                body: Self.defaultRequestBody()),
            context: RequestContext(
                httpsPort: connectPort,
                httpPort: processInfo.extensionPort,
                csrfToken: processInfo.csrfToken,
                timeout: self.timeout))
        return try Self.parsePlanInfoSummary(response)
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
        let planName = userStatus.planStatus?.planInfo?.preferredName

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

    private struct ProcessInfoResult: Sendable {
        let pid: Int
        let extensionPort: Int?
        let csrfToken: String
        let commandLine: String
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
            return ProcessInfoResult(pid: match.pid, extensionPort: port, csrfToken: token, commandLine: match.command)
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
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-p", String(pid)],
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

    private static func findWorkingPort(
        ports: [Int],
        csrfToken: String,
        timeout: TimeInterval) async throws -> Int
    {
        for port in ports {
            let ok = await Self.testPortConnectivity(port: port, csrfToken: csrfToken, timeout: timeout)
            if ok { return port }
        }
        throw AntigravityStatusProbeError.portDetectionFailed("no working API port found")
    }

    private static func testPortConnectivity(
        port: Int,
        csrfToken: String,
        timeout: TimeInterval) async -> Bool
    {
        do {
            _ = try await self.makeRequest(
                payload: RequestPayload(
                    path: self.unleashPath,
                    body: self.unleashRequestBody()),
                context: RequestContext(
                    httpsPort: port,
                    httpPort: nil,
                    csrfToken: csrfToken,
                    timeout: timeout))
            return true
        } catch {
            #if canImport(os.log)
            if #available(macOS 13.0, *) {
                self.log
                    .debug("[Antigravity] Port \(port) probe failed: \(error.localizedDescription, privacy: .public)")
            }
            #endif
            return false
        }
    }

    // MARK: - HTTP

    private struct RequestPayload {
        let path: String
        let body: [String: Any]
    }

    private struct RequestContext: Sendable {
        let httpsPort: Int
        let httpPort: Int?
        let csrfToken: String
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
        do {
            return try await self.sendRequest(
                scheme: "https",
                port: context.httpsPort,
                payload: payload,
                context: context)
        } catch {
            guard let httpPort = context.httpPort, httpPort != context.httpsPort else { throw error }
            return try await Self.sendRequest(
                scheme: "http",
                port: httpPort,
                payload: payload,
                context: context)
        }
    }

    private static func sendRequest(
        scheme: String,
        port: Int,
        payload: RequestPayload,
        context: RequestContext) async throws -> Data
    {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(payload.path)") else {
            throw AntigravityStatusProbeError.apiError("Invalid URL")
        }

        let body = try JSONSerialization.data(withJSONObject: payload.body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = context.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(context.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = context.timeout
        config.timeoutIntervalForResource = context.timeout
        let session = URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
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

private final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
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
