import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum IBMBobUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case noSubscription
    case apiError(Int)
    case untrustedRegion(String)
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing IBM Bob API key. Add one in Settings or set BOBSHELL_API_KEY."
        case .invalidCredentials:
            "IBM Bob rejected the API key. Check that it is active and can read subscription usage."
        case .noSubscription:
            "IBM Bob returned no subscription instances or teams for this API key."
        case let .apiError(statusCode):
            "IBM Bob API returned HTTP \(statusCode)."
        case let .untrustedRegion(host):
            "IBM Bob returned an untrusted regional API host: \(host)."
        case let .parseFailed(message):
            "Could not parse IBM Bob usage: \(message)"
        case let .networkError(message):
            "IBM Bob network error: \(message)"
        }
    }
}

public struct IBMBobUsageSnapshot: Sendable, Equatable {
    public struct TeamUsage: Sendable, Equatable {
        public let instanceName: String
        public let teamName: String
        public let planName: String?
        public let usedBobcoins: Double
        public let limitBobcoins: Double?
        public let resetsAt: Date?
    }

    public let teams: [TeamUsage]
    public let updatedAt: Date

    public var usedBobcoins: Double {
        self.teams.reduce(0) { $0 + $1.usedBobcoins }
    }

    public var limitBobcoins: Double? {
        let limits = self.teams.compactMap(\.limitBobcoins)
        guard limits.count == self.teams.count, !limits.isEmpty else { return nil }
        return limits.reduce(0, +)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let used = self.usedBobcoins
        let limit = self.limitBobcoins
        let reset = self.teams.compactMap(\.resetsAt).min()
        let usedPercent = limit.flatMap { $0 > 0 ? min(100, max(0, used / $0 * 100)) : nil }
        let summary = limit.map { "\(Self.bobcoins(used)) / \(Self.bobcoins($0)) Bobcoins" }
            ?? "\(Self.bobcoins(used)) Bobcoins used"
        let planNames = Array(Set(self.teams.compactMap(\.planName))).sorted()

        let rows = self.teams.map { team in
            let value = team.limitBobcoins.map {
                "\(Self.bobcoins(team.usedBobcoins)) / \(Self.bobcoins($0)) Bobcoins"
            } ?? "\(Self.bobcoins(team.usedBobcoins)) Bobcoins used"
            let label = team.teamName == team.instanceName
                ? team.teamName
                : "\(team.instanceName) · \(team.teamName)"
            return ProviderDetailSection.Row.makeRow(
                label: label,
                value: value,
                secondaryValue: team.planName)
        }

        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent ?? 0,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: reset,
                resetDescription: summary),
            secondary: nil,
            details: [.makeSection(title: "Bobcoin usage", rows: rows)],
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .ibmbob,
                accountEmail: nil,
                accountOrganization: planNames.isEmpty ? nil : planNames.joined(separator: ", "),
                loginMethod: "API key"),
            dataConfidence: .exact)
    }

    private static func bobcoins(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

private struct IBMBobProfileResponse: Decodable {
    struct Instance: Decodable {
        struct Team: Decodable {
            let id: String
            let name: String?
            let budgetLimit: Double?
            let usage: Double?

            enum CodingKeys: String, CodingKey {
                case id
                case name
                case budgetLimit = "budget_limit"
                case usage
            }
        }

        let instanceID: String
        let instanceName: String?
        let legacyName: String?
        let userID: String?
        let planName: String?
        let refreshAt: IBMBobRefreshAt?
        let regionDomain: String?
        let teams: [Team]

        var name: String? {
            self.instanceName ?? self.legacyName
        }

        enum CodingKeys: String, CodingKey {
            case instanceID = "instance_id"
            case instanceName = "instance_name"
            case legacyName = "name"
            case userID = "user_id"
            case planName = "plan_name"
            case refreshAt = "refresh_at"
            case regionDomain = "region_domain"
            case teams
        }
    }

    let instances: [Instance]
}

private enum IBMBobRefreshAt: Decodable {
    case seconds(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self = .seconds(seconds)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected IBM Bob refresh_at to be Unix seconds or an ISO-8601 string.")
        }
    }
}

private struct IBMBobTeamBudgetResponse: Decodable {
    let usage: Double
    let budgetLimit: Double?

    enum CodingKeys: String, CodingKey {
        case usage
        case budgetLimit = "budget_limit"
    }
}

public enum IBMBobUsageFetcher {
    private static let baseURL = URL(string: "https://api.us-east.bob.ibm.com")!
    private static let timeoutSeconds: TimeInterval = 20

    public static func fetchUsage(apiKey: String) async throws -> IBMBobUsageSnapshot {
        try await self.fetchUsage(
            apiKey: apiKey,
            transport: ProviderHTTPClient.shared,
            now: Date())
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> IBMBobUsageSnapshot
    {
        try await self.fetchUsage(apiKey: apiKey, transport: transport, now: now)
    }

    static func _parseProfileForTesting(_ data: Data) throws -> Int {
        try self.decodeProfile(data).instances.count
    }

    private static func fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> IBMBobUsageSnapshot
    {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw IBMBobUsageError.missingCredentials }

        do {
            let profileResponse = try await transport.response(
                for: self.request(
                    url: self.baseURL.appending(path: "admin/v1/profile"),
                    token: token,
                    instanceID: nil,
                    teamID: nil),
                retryPolicy: .transientIdempotent)
            try self.validate(profileResponse)
            let profile = try self.decodeProfile(profileResponse.data)

            var teamUsage: [IBMBobUsageSnapshot.TeamUsage] = []
            for instance in profile.instances {
                guard let userID = instance.userID, !userID.isEmpty else { continue }
                let regionalBaseURL = try self.regionalBaseURL(instance.regionDomain)
                for team in instance.teams {
                    guard !team.id.isEmpty else { continue }
                    let url = regionalBaseURL
                        .appending(path: "admin/v1/teams")
                        .appending(path: team.id)
                        .appending(path: "users")
                        .appending(path: userID)
                    let response = try await transport.response(
                        for: self.request(
                            url: url,
                            token: token,
                            instanceID: instance.instanceID,
                            teamID: team.id),
                        retryPolicy: .transientIdempotent)
                    try self.validate(response)
                    let budget = try JSONDecoder().decode(IBMBobTeamBudgetResponse.self, from: response.data)
                    let limit = (budget.budgetLimit ?? team.budgetLimit).flatMap { $0 >= 0 ? $0 : nil }
                    let instanceName = Self.nonEmpty(instance.name) ?? instance.instanceID
                    let teamName = Self.nonEmpty(team.name) ?? team.id
                    teamUsage.append(IBMBobUsageSnapshot.TeamUsage(
                        instanceName: instanceName,
                        teamName: teamName,
                        planName: Self.nonEmpty(instance.planName),
                        usedBobcoins: max(0, budget.usage),
                        limitBobcoins: limit,
                        resetsAt: self.parseDate(instance.refreshAt)))
                }
            }
            guard !teamUsage.isEmpty else { throw IBMBobUsageError.noSubscription }
            return IBMBobUsageSnapshot(teams: teamUsage, updatedAt: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IBMBobUsageError {
            throw error
        } catch let error as DecodingError {
            throw IBMBobUsageError.parseFailed(error.localizedDescription)
        } catch {
            throw IBMBobUsageError.networkError(error.localizedDescription)
        }
    }

    private static func request(
        url: URL,
        token: String,
        instanceID: String?,
        teamID: String?) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.authorizationValue(token), forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        if let instanceID {
            request.setValue(instanceID, forHTTPHeaderField: "x-instance-id")
        }
        if let teamID {
            request.setValue(teamID, forHTTPHeaderField: "x-team-id")
        }
        return request
    }

    private static func authorizationValue(_ token: String) -> String {
        self.isJWT(token) ? "Bearer \(token)" : "Apikey \(token)"
    }

    private static func isJWT(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else {
            return false
        }
        return true
    }

    private static func regionalBaseURL(_ regionDomain: String?) throws -> URL {
        guard let domain = self.nonEmpty(regionDomain) else { return self.baseURL }
        let host = domain.lowercased().hasPrefix("api.") ? domain : "api.\(domain)"
        guard let url = URL(string: "https://\(host)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let parsedHost = url.host?.lowercased(),
              parsedHost == "bob.ibm.com" || parsedHost.hasSuffix(".bob.ibm.com")
        else {
            throw IBMBobUsageError.untrustedRegion(host)
        }
        return url
    }

    private static func validate(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw IBMBobUsageError.invalidCredentials
        default:
            throw IBMBobUsageError.apiError(response.statusCode)
        }
    }

    private static func decodeProfile(_ data: Data) throws -> IBMBobProfileResponse {
        do {
            return try JSONDecoder().decode(IBMBobProfileResponse.self, from: data)
        } catch {
            throw IBMBobUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseDate(_ value: IBMBobRefreshAt?) -> Date? {
        guard let value else { return nil }
        switch value {
        case let .seconds(seconds):
            guard seconds.isFinite, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        case let .text(text):
            return self.parseISO8601Date(text)
        }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        guard let value = self.nonEmpty(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
