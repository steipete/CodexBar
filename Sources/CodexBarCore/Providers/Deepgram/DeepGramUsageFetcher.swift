import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DeepgramUsageError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidCredentials
    case invalidProjectID
    case forbidden(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Deepgram API key is missing."
        case .invalidCredentials:
            "Deepgram API key is invalid or expired."
        case .invalidProjectID:
            "Deepgram project ID is missing."
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

// MARK: - Deepgram Usage API Response

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
    public let requests: Int?

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case hours
        case totalHours = "total_hours"
        case requests
    }
}

// MARK: - Query

public struct DeepgramUsageQuery: Sendable {
    public var start: String?
    public var end: String?

    public init(
        start: String? = nil,
        end: String? = nil
    ) {
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
    public let start: String?
    public let end: String?
    public let hours: Double
    public let totalHours: Double
    public let requests: Int
    public let updatedAt: Date

    public init(
        projectID: String,
        start: String?,
        end: String?,
        hours: Double,
        totalHours: Double,
        requests: Int,
        updatedAt: Date
    ) {
        self.projectID = projectID
        self.start = start
        self.end = end
        self.hours = hours
        self.totalHours = totalHours
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
            loginMethod: "Project: \(self.projectID)"
        )

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            deepgramUsage: self,
            updatedAt: self.updatedAt,
            identity: identity
        )
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

        if let start, let end {
            lines.append("Period: \(start) to \(end)")
        }

        return lines
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
    private static let log = CodexBarLog.logger(LogCategories.deepGramUsage)
    private static let defaultBaseURL = URL(string: "https://api.deepgram.com/v1")!

    public static func fetchUsage(
        apiKey: String,
        projectID: String,
        query: DeepgramUsageQuery = DeepgramUsageQuery(),
        timeout: TimeInterval = 15,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) async throws -> DeepgramUsageSnapshot {
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedAPIKey.isEmpty else {
            throw DeepgramUsageError.missingAPIKey
        }

        guard !cleanedProjectID.isEmpty else {
            throw DeepgramUsageError.invalidProjectID
        }

        let url = try self.usageURL(
            projectID: cleanedProjectID,
            query: query,
            environment: environment
        )

        Self.log.info("Deepgram usage URL: \(url.absoluteString)")
        Self.log.info("Deepgram project ID present: \(!cleanedProjectID.isEmpty)")
        Self.log.info("Deepgram project ID length: \(cleanedProjectID.count)")
        Self.log.info("Deepgram API key present: \(!cleanedAPIKey.isEmpty)")
        Self.log.info("Deepgram API key length: \(cleanedAPIKey.count)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Token \(cleanedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeepgramUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let summary = self.responseSummary(data)
            Self.log.error("Deepgram returned HTTP \(httpResponse.statusCode): \(summary)")

            switch httpResponse.statusCode {
            case 401:
                throw DeepgramUsageError.invalidCredentials

            case 403:
                throw DeepgramUsageError.forbidden(
                    "The API key was recognized, but it may not have access to this project or the Deepgram Management API. HTTP 403: \(summary)"
                )

            case 400:
                throw DeepgramUsageError.apiError("Bad request. HTTP 400: \(summary)")

            default:
                throw DeepgramUsageError.apiError("HTTP \(httpResponse.statusCode): \(summary)")
            }
        }

        return try self.parseUsage(
            data: data,
            projectID: cleanedProjectID,
            updatedAt: Date()
        )
    }

    private static func usageURL(
        projectID: String,
        query: DeepgramUsageQuery,
        environment: [String: String]
    ) throws -> URL {
        let baseURL = self.apiURL(environment: environment)

        let usageURL = baseURL
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
        if let raw = environment["DEEPGRAM_API_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw)
        {
            return url
        }

        return self.defaultBaseURL
    }

    private static func parseUsage(
        data: Data,
        projectID: String,
        updatedAt: Date
    ) throws -> DeepgramUsageSnapshot {
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(DeepgramUsageResponse.self, from: data)

            let hours = response.results.reduce(0) { $0 + ($1.hours ?? 0) }
            let totalHours = response.results.reduce(0) { $0 + ($1.totalHours ?? 0) }
            let requests = response.results.reduce(0) { $0 + ($1.requests ?? 0) }

            return DeepgramUsageSnapshot(
                projectID: projectID,
                start: response.start,
                end: response.end,
                hours: hours,
                totalHours: totalHours,
                requests: requests,
                updatedAt: updatedAt
            )
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

    static func _parseSnapshotForTesting(
        _ data: Data,
        projectID: String = "project-test",
        updatedAt: Date = Date()
    ) throws -> DeepgramUsageSnapshot {
        try self.parseUsage(
            data: data,
            projectID: projectID,
            updatedAt: updatedAt
        )
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
        return self.redact("\(cleaned[..<index])… [truncated]")
    }

    private static func redact(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)(token\s+)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (#"(?i)(dg_[A-Za-z0-9._\-]+)"#, "[REDACTED]"),
            (
                #"(?i)(\"(?:api_?key|authorization|token|access_token|refresh_token)\"\s*:\s*\")([^\"]+)(\")"#,
                "$1[REDACTED]$3"
            )
        ]

        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }
}
