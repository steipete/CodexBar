import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DeepgramUsageError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidEndpointOverride(String)
    case invalidCredentials
    case invalidProjectID
    case forbidden(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Missing Deepgram API key. Set apiKey in ~/.codexbar/config.json or DEEPGRAM_API_KEY."
        case let .invalidEndpointOverride(key):
            "Deepgram endpoint override \(key) must use HTTPS or a bare host."
        case .invalidCredentials:
            "Deepgram API key is invalid or expired."
        case .invalidProjectID:
            "Deepgram project ID is invalid or no projects were returned for this API key."
        case let .forbidden(message):
            "Deepgram rejected access: \(message)"
        case let .networkError(message):
            "Deepgram network error: \(message)"
        case let .apiError(message):
            "Deepgram API error: \(message)"
        case let .parseFailed(message):
            "Deepgram parse error: \(message)"
        }
    }
}

// MARK: - API Responses

public struct DeepgramProjectsResponse: Decodable, Sendable {
    public let projects: [DeepgramProject]
}

public struct DeepgramProject: Decodable, Sendable, Equatable {
    public let projectID: String
    public let name: String?

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case name
    }

    public init(projectID: String, name: String? = nil) {
        self.projectID = projectID
        self.name = name
    }
}

public struct DeepgramUsageResponse: Decodable, Sendable {
    public let start: String?
    public let end: String?
    public let resolution: DeepgramUsageResolution?
    public let results: [DeepgramUsageResult]
}

public struct DeepgramUsageResolution: Decodable, Sendable {
    public let units: String?
    public let amount: Int?
}

public struct DeepgramUsageResult: Codable, Sendable {
    public let start: String?
    public let end: String?
    public let hours: Double?
    public let totalHours: Double?
    public let agentHours: Double?
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let ttsCharacters: Int?
    public let requests: Int?

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case hours
        case totalHours = "total_hours"
        case agentHours = "agent_hours"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case ttsCharacters = "tts_characters"
        case requests
    }
}

// MARK: - Query

public struct DeepgramUsageQuery: Sendable {
    public var start: String?
    public var end: String?

    public init(
        start: String? = nil,
        end: String? = nil)
    {
        self.start = start
        self.end = end
    }

    public func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        func add(_ name: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return
            }
            items.append(URLQueryItem(name: name, value: value))
        }

        add("start", self.start)
        add("end", self.end)

        return items
    }
}

// MARK: - Snapshot

public struct DeepgramUsageSnapshot: Codable, Sendable {
    public let projectID: String
    public let projectName: String?
    public let projectCount: Int
    public let start: String?
    public let end: String?
    public let hours: Double
    public let totalHours: Double
    public let agentHours: Double
    public let tokensIn: Int
    public let tokensOut: Int
    public let ttsCharacters: Int
    public let requests: Int
    public let updatedAt: Date

    public init(
        projectID: String,
        projectName: String? = nil,
        projectCount: Int = 1,
        start: String?,
        end: String?,
        hours: Double,
        totalHours: Double,
        agentHours: Double = 0,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        ttsCharacters: Int = 0,
        requests: Int,
        updatedAt: Date)
    {
        self.projectID = projectID
        self.projectName = projectName
        self.projectCount = projectCount
        self.start = start
        self.end = end
        self.hours = hours
        self.totalHours = totalHours
        self.agentHours = agentHours
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.ttsCharacters = ttsCharacters
        self.requests = requests
        self.updatedAt = updatedAt
    }
}

extension DeepgramUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .deepgram,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.identityLabel)

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            deepgramUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    public var displayLines: [String] {
        var lines: [String] = []
        lines.append("Requests: \(Self.formatInteger(self.requests))")

        var usageParts: [String] = []
        if self.hours > 0 {
            usageParts.append("\(Self.formatDecimal(self.hours)) audio hours")
        }
        if self.totalHours > 0 {
            usageParts.append("\(Self.formatDecimal(self.totalHours)) billable hours")
        }
        if !usageParts.isEmpty {
            lines.append(usageParts.joined(separator: " · "))
        }

        var modelParts: [String] = []
        if self.agentHours > 0 {
            modelParts.append("\(Self.formatDecimal(self.agentHours)) agent hours")
        }
        if self.tokensIn > 0 || self.tokensOut > 0 {
            modelParts.append("\(Self.formatInteger(self.tokensIn + self.tokensOut)) tokens")
        }
        if self.ttsCharacters > 0 {
            modelParts.append("\(Self.formatInteger(self.ttsCharacters)) TTS chars")
        }
        if !modelParts.isEmpty {
            lines.append(modelParts.joined(separator: " · "))
        }

        if let start, let end {
            lines.append("Period: \(start) to \(end)")
        }

        return lines
    }

    private var identityLabel: String? {
        if self.projectCount > 1 {
            return "\(self.projectCount) projects"
        }
        if let projectName = self.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectName.isEmpty
        {
            return "Project: \(projectName)"
        }
        return "Project: \(self.projectID)"
    }

    fileprivate static func aggregate(
        _ snapshots: [DeepgramUsageSnapshot],
        updatedAt: Date) throws -> DeepgramUsageSnapshot
    {
        guard let first = snapshots.first else {
            throw DeepgramUsageError.invalidProjectID
        }
        if snapshots.count == 1 { return first }
        return DeepgramUsageSnapshot(
            projectID: "all",
            projectName: nil,
            projectCount: snapshots.count,
            start: snapshots.compactMap(\.start).min(),
            end: snapshots.compactMap(\.end).max(),
            hours: snapshots.reduce(0) { $0 + $1.hours },
            totalHours: snapshots.reduce(0) { $0 + $1.totalHours },
            agentHours: snapshots.reduce(0) { $0 + $1.agentHours },
            tokensIn: snapshots.reduce(0) { $0 + $1.tokensIn },
            tokensOut: snapshots.reduce(0) { $0 + $1.tokensOut },
            ttsCharacters: snapshots.reduce(0) { $0 + $1.ttsCharacters },
            requests: snapshots.reduce(0) { $0 + $1.requests },
            updatedAt: updatedAt)
    }

    private static func formatInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatDecimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = value == floor(value) ? 0 : 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}

// MARK: - Fetcher

public struct DeepgramUsageFetcher: Sendable {
    public static let apiURLKey = "DEEPGRAM_API_URL"

    private static let log = CodexBarLog.logger(LogCategories.deepgramUsage)
    private static let defaultBaseURL = URL(string: "https://api.deepgram.com/v1")!

    private struct FetchContext {
        let apiKey: String
        let query: DeepgramUsageQuery
        let timeout: TimeInterval
        let environment: [String: String]
        let transport: ProviderHTTPTransport
        let updatedAt: Date
    }

    public static func fetchUsage(
        apiKey: String,
        projectID: String? = nil,
        query: DeepgramUsageQuery = DeepgramUsageQuery(),
        timeout: TimeInterval = 15,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> DeepgramUsageSnapshot
    {
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAPIKey.isEmpty else {
            throw DeepgramUsageError.missingAPIKey
        }
        try self.validateEndpointOverrides(environment: environment)

        let updatedAt = Date()
        let context = FetchContext(
            apiKey: cleanedAPIKey,
            query: query,
            timeout: timeout,
            environment: environment,
            transport: transport,
            updatedAt: updatedAt)

        if let cleanedProjectID = self.cleaned(projectID) {
            return try await self.fetchUsage(
                project: DeepgramProject(projectID: cleanedProjectID),
                context: context)
        }

        let projects = try await self.listProjects(
            apiKey: cleanedAPIKey,
            timeout: timeout,
            environment: environment,
            transport: transport)
        guard !projects.isEmpty else {
            throw DeepgramUsageError.invalidProjectID
        }

        var snapshots: [DeepgramUsageSnapshot] = []
        snapshots.reserveCapacity(projects.count)
        for project in projects {
            let snapshot = try await self.fetchUsage(
                project: project,
                context: context)
            snapshots.append(snapshot)
        }
        return try DeepgramUsageSnapshot.aggregate(snapshots, updatedAt: updatedAt)
    }

    static func _parseSnapshotForTesting(
        _ data: Data,
        projectID: String = "project-test",
        projectName: String? = nil,
        updatedAt: Date = Date()) throws -> DeepgramUsageSnapshot
    {
        try self.parseUsage(
            data: data,
            project: DeepgramProject(projectID: projectID, name: projectName),
            updatedAt: updatedAt)
    }

    private static func listProjects(
        apiKey: String,
        timeout: TimeInterval,
        environment: [String: String],
        transport: ProviderHTTPTransport) async throws -> [DeepgramProject]
    {
        let url = self.apiURL(environment: environment).appendingPathComponent("projects")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await self.perform(request: request, transport: transport)
        do {
            return try JSONDecoder().decode(DeepgramProjectsResponse.self, from: response.data).projects
        } catch {
            Self.log.error("Deepgram projects decode failed: \(error.localizedDescription)")
            throw DeepgramUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func fetchUsage(
        project: DeepgramProject,
        context: FetchContext) async throws -> DeepgramUsageSnapshot
    {
        let url = try self.usageURL(
            projectID: project.projectID,
            query: context.query,
            environment: context.environment)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = context.timeout
        request.setValue("Token \(context.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await self.perform(request: request, transport: context.transport)
        return try self.parseUsage(data: response.data, project: project, updatedAt: context.updatedAt)
    }

    private static func perform(
        request: URLRequest,
        transport: ProviderHTTPTransport) async throws -> ProviderHTTPResponse
    {
        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw DeepgramUsageError.networkError(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            let summary = self.responseSummary(response.data)
            Self.log.error("Deepgram returned HTTP \(response.statusCode): \(summary)")

            switch response.statusCode {
            case 401:
                throw DeepgramUsageError.invalidCredentials
            case 403:
                throw DeepgramUsageError.forbidden(
                    "The API key may not have access to the project or the Management API. HTTP 403: \(summary)")
            case 400:
                throw DeepgramUsageError.apiError("Bad request. HTTP 400: \(summary)")
            default:
                throw DeepgramUsageError.apiError("HTTP \(response.statusCode): \(summary)")
            }
        }

        return response
    }

    private static func usageURL(
        projectID: String,
        query: DeepgramUsageQuery,
        environment: [String: String]) throws -> URL
    {
        let usageURL = self.apiURL(environment: environment)
            .appendingPathComponent("projects")
            .appendingPathComponent(projectID)
            .appendingPathComponent("usage")
            .appendingPathComponent("breakdown")

        guard var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false) else {
            throw DeepgramUsageError.networkError("Invalid usage URL")
        }

        let queryItems = query.queryItems()
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let finalURL = components.url else {
            throw DeepgramUsageError.networkError("Invalid usage query")
        }

        return finalURL
    }

    private static func apiURL(environment: [String: String]) -> URL {
        if let raw = self.cleaned(environment[self.apiURLKey]),
           let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
        {
            return url
        }

        return self.defaultBaseURL
    }

    public static func validateEndpointOverrides(environment: [String: String] = ProcessInfo.processInfo
        .environment) throws
    {
        guard let raw = self.cleaned(environment[self.apiURLKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw DeepgramUsageError.invalidEndpointOverride(self.apiURLKey)
    }

    private static func parseUsage(
        data: Data,
        project: DeepgramProject,
        updatedAt: Date) throws -> DeepgramUsageSnapshot
    {
        do {
            let response = try JSONDecoder().decode(DeepgramUsageResponse.self, from: data)
            return DeepgramUsageSnapshot(
                projectID: project.projectID,
                projectName: project.name,
                start: response.start,
                end: response.end,
                hours: response.results.reduce(0) { $0 + ($1.hours ?? 0) },
                totalHours: response.results.reduce(0) { $0 + ($1.totalHours ?? 0) },
                agentHours: response.results.reduce(0) { $0 + ($1.agentHours ?? 0) },
                tokensIn: response.results.reduce(0) { $0 + ($1.tokensIn ?? 0) },
                tokensOut: response.results.reduce(0) { $0 + ($1.tokensOut ?? 0) },
                ttsCharacters: response.results.reduce(0) { $0 + ($1.ttsCharacters ?? 0) },
                requests: response.results.reduce(0) { $0 + ($1.requests ?? 0) },
                updatedAt: updatedAt)
        } catch let error as DecodingError {
            Self.log.error("Deepgram decoding error: \(error.localizedDescription)")
            Self.log.error("Deepgram raw response: \(self.responseSummary(data))")
            throw DeepgramUsageError.parseFailed(error.localizedDescription)
        } catch {
            Self.log.error("Deepgram parse error: \(error.localizedDescription)")
            Self.log.error("Deepgram raw response: \(self.responseSummary(data))")
            throw DeepgramUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func responseSummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }

        guard let text = String(data: data, encoding: .utf8) else {
            return "non-text body (\(data.count) bytes)"
        }

        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return "empty body"
        }

        let maxLength = 240
        guard cleaned.count > maxLength else {
            return self.redact(cleaned)
        }

        let index = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        return self.redact("\(cleaned[..<index])... [truncated]")
    }

    private static func redact(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)(token\s+)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (#"(?i)(dg_[A-Za-z0-9._\-]+)"#, "[REDACTED]"),
            (
                #"(?i)(\"(?:api_?key|authorization|token|access_token|refresh_token)\"\s*:\s*\")([^\"]+)(\")"#,
                "$1[REDACTED]$3"),
        ]

        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression)
        }
    }
}
