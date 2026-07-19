import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LiteLLMUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingBaseURL
    case missingUserID
    case invalidURL
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing LiteLLM API key. Set apiKey in ~/.codexbar/config.json or LITELLM_API_KEY."
        case .missingBaseURL:
            "Missing LiteLLM base URL. Set enterpriseHost in ~/.codexbar/config.json or LITELLM_BASE_URL."
        case .missingUserID:
            "LiteLLM key info did not include a user_id or team_id."
        case .invalidURL:
            "LiteLLM URL is invalid."
        case let .apiError(message):
            "LiteLLM API error: \(message)"
        case let .parseFailed(message):
            "LiteLLM parse error: \(message)"
        }
    }
}

public struct LiteLLMKeyInfoSnapshot: Codable, Sendable, Equatable {
    public let userID: String?
    public let teamID: String?
    public let keyName: String?
    public let spendUSD: Double
    public let expiresAt: Date?

    public init(userID: String?, teamID: String?, keyName: String?, spendUSD: Double, expiresAt: Date?) {
        self.userID = userID
        self.teamID = teamID
        self.keyName = keyName
        self.spendUSD = spendUSD
        self.expiresAt = expiresAt
    }
}

public struct LiteLLMUsageSnapshot: Codable, Sendable, Equatable {
    public let userID: String?
    public let accountEmail: String?
    public let personalSpendUSD: Double
    public let personalBudgetUSD: Double?
    public let personalResetAt: Date?
    public let teamUsage: TeamUsage?
    public let keyName: String?
    public let keyExpiresAt: Date?
    public let updatedAt: Date

    public struct TeamUsage: Codable, Sendable, Equatable {
        public let id: String
        public let alias: String?
        public let spendUSD: Double
        public let budgetUSD: Double?
        public let resetAt: Date?
        public let budgetDuration: String?
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = Self.rateWindow(
            spend: self.personalSpendUSD,
            budget: self.personalBudgetUSD,
            resetAt: self.personalResetAt,
            description: Self.budgetDescription(spend: self.personalSpendUSD, budget: self.personalBudgetUSD))

        let secondary = self.teamUsage.flatMap { team in
            Self.rateWindow(
                spend: team.spendUSD,
                budget: team.budgetUSD,
                resetAt: team.resetAt,
                description: Self.teamDescription(team))
        }

        let providerCost = self.providerCostSnapshot()

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: providerCost,
            subscriptionExpiresAt: self.keyExpiresAt,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .litellm,
                accountEmail: self.accountEmail,
                accountOrganization: self.teamUsage?.alias,
                loginMethod: "api"))
    }

    private static func rateWindow(
        spend: Double,
        budget: Double?,
        resetAt: Date?,
        description: String?) -> RateWindow?
    {
        guard let budget, budget > 0 else { return nil }
        return RateWindow(
            usedPercent: min(100, max(0, (spend / budget) * 100)),
            windowMinutes: nil,
            resetsAt: resetAt,
            resetDescription: description)
    }

    private static func budgetDescription(spend: Double, budget: Double?) -> String? {
        guard let budget, budget > 0 else { return UsageFormatter.usdString(spend) }
        return "\(UsageFormatter.usdString(spend)) / \(UsageFormatter.usdString(budget))"
    }

    private static func teamDescription(_ team: TeamUsage) -> String? {
        let label = team.alias.map { "Team \($0)" } ?? "Team"
        guard let budget = team.budgetUSD, budget > 0 else {
            return "\(label): \(UsageFormatter.usdString(team.spendUSD))"
        }
        return "\(label): \(UsageFormatter.usdString(team.spendUSD)) / \(UsageFormatter.usdString(budget))"
    }

    private func providerCostSnapshot() -> ProviderCostSnapshot? {
        let spend: Double
        let budget: Double?
        let period: String
        let resetsAt: Date?

        if self.userID == nil, let team = self.teamUsage {
            spend = team.spendUSD
            budget = team.budgetUSD
            period = (team.budgetUSD ?? 0) > 0 ? "Team budget" : "Team spend"
            resetsAt = team.resetAt
        } else {
            spend = self.personalSpendUSD
            budget = self.personalBudgetUSD
            period = (self.personalBudgetUSD ?? 0) > 0 ? "Personal budget" : "Personal spend"
            resetsAt = self.personalResetAt
        }

        guard spend > 0 || (budget ?? 0) > 0 else { return nil }
        return ProviderCostSnapshot(
            used: spend,
            limit: max(0, budget ?? 0),
            currencyCode: "USD",
            period: period,
            resetsAt: resetsAt,
            updatedAt: self.updatedAt)
    }
}

private struct LiteLLMKeyInfoResponse: Decodable {
    struct Info: Decodable {
        let keyName: String?
        let spend: Double?
        let expires: String?
        let userID: String?
        let teamID: String?

        private enum CodingKeys: String, CodingKey {
            case keyName = "key_name"
            case spend
            case expires
            case userID = "user_id"
            case teamID = "team_id"
        }
    }

    let info: Info
}

private struct LiteLLMUserInfoResponse: Decodable {
    struct UserInfo: Decodable {
        struct Metadata: Decodable {
            let preferredUsername: String?

            private enum CodingKeys: String, CodingKey {
                case preferredUsername = "preferred_username"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.preferredUsername = try? container.decodeIfPresent(String.self, forKey: .preferredUsername)
            }
        }

        let userID: String?
        let userAlias: String?
        let maxBudget: Double?
        let spend: Double?
        let userEmail: String?
        let budgetResetAt: String?
        let metadata: Metadata?

        private enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case userAlias = "user_alias"
            case maxBudget = "max_budget"
            case spend
            case userEmail = "user_email"
            case budgetResetAt = "budget_reset_at"
            case metadata
        }
    }

    struct Team: Decodable {
        let teamAlias: String?
        let teamID: String
        let maxBudget: Double?
        let spend: Double?
        let budgetResetAt: String?
        let budgetDuration: String?

        private enum CodingKeys: String, CodingKey {
            case teamAlias = "team_alias"
            case teamID = "team_id"
            case maxBudget = "max_budget"
            case spend
            case budgetResetAt = "budget_reset_at"
            case budgetDuration = "budget_duration"
        }
    }

    let userID: String?
    let userInfo: UserInfo
    let teams: [Team]?

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case userInfo = "user_info"
        case teams
    }
}

private struct LiteLLMTeamInfoResponse: Decodable {
    struct TeamInfo: Decodable {
        let teamAlias: String?
        let teamID: String?
        let maxBudget: Double?
        let spend: Double?
        let budgetResetAt: String?
        let budgetDuration: String?

        private enum CodingKeys: String, CodingKey {
            case teamAlias = "team_alias"
            case teamID = "team_id"
            case maxBudget = "max_budget"
            case spend
            case budgetResetAt = "budget_reset_at"
            case budgetDuration = "budget_duration"
        }
    }

    let teamID: String?
    let teamInfo: TeamInfo

    private enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case teamInfo = "team_info"
    }
}

public struct LiteLLMUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> LiteLLMUsageSnapshot
    {
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAPIKey.isEmpty else {
            throw LiteLLMUsageError.missingCredentials
        }

        let keyInfo = try await self.fetchKeyInfo(
            apiKey: cleanedAPIKey,
            baseURL: baseURL,
            transport: transport)
        if keyInfo.userID != nil {
            return try await self.fetchUserInfo(
                apiKey: cleanedAPIKey,
                baseURL: baseURL,
                keyInfo: keyInfo,
                transport: transport,
                updatedAt: updatedAt)
        }
        if keyInfo.teamID != nil {
            return try await self.fetchTeamInfo(
                apiKey: cleanedAPIKey,
                baseURL: baseURL,
                keyInfo: keyInfo,
                transport: transport,
                updatedAt: updatedAt)
        }
        throw LiteLLMUsageError.missingUserID
    }

    public static func _parseUserInfoForTesting(
        _ data: Data,
        keyInfo: LiteLLMKeyInfoSnapshot,
        updatedAt: Date) throws -> LiteLLMUsageSnapshot
    {
        try self.parseUserInfo(data: data, keyInfo: keyInfo, updatedAt: updatedAt)
    }

    public static func _parseKeyInfoForTesting(_ data: Data) throws -> LiteLLMKeyInfoSnapshot {
        try self.parseKeyInfo(data: data)
    }

    public static func _parseTeamInfoForTesting(
        _ data: Data,
        keyInfo: LiteLLMKeyInfoSnapshot,
        updatedAt: Date) throws -> LiteLLMUsageSnapshot
    {
        try self.parseTeamInfo(data: data, keyInfo: keyInfo, updatedAt: updatedAt)
    }

    public static func _keyInfoURLForTesting(baseURL: URL) -> URL {
        self.keyInfoURL(baseURL: baseURL)
    }

    public static func _userInfoURLForTesting(baseURL: URL, userID: String) -> URL {
        self.userInfoURL(baseURL: baseURL, userID: userID)
    }

    public static func _teamInfoURLForTesting(baseURL: URL, teamID: String) -> URL {
        self.teamInfoURL(baseURL: baseURL, teamID: teamID)
    }

    private static func fetchKeyInfo(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> LiteLLMKeyInfoSnapshot
    {
        // Virtual keys may read their own metadata; omit ?key= to avoid requiring or exposing a master key.
        let request = self.request(
            url: self.keyInfoURL(baseURL: baseURL),
            apiKey: apiKey)
        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LiteLLMUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseKeyInfo(data: response.data)
    }

    private static func fetchUserInfo(
        apiKey: String,
        baseURL: URL,
        keyInfo: LiteLLMKeyInfoSnapshot,
        transport: any ProviderHTTPTransport,
        updatedAt: Date) async throws -> LiteLLMUsageSnapshot
    {
        guard let userID = keyInfo.userID else {
            throw LiteLLMUsageError.parseFailed("/user/info requested without a user_id")
        }
        let request = self.request(
            url: self.userInfoURL(baseURL: baseURL, userID: userID),
            apiKey: apiKey)
        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LiteLLMUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseUserInfo(data: response.data, keyInfo: keyInfo, updatedAt: updatedAt)
    }

    private static func fetchTeamInfo(
        apiKey: String,
        baseURL: URL,
        keyInfo: LiteLLMKeyInfoSnapshot,
        transport: any ProviderHTTPTransport,
        updatedAt: Date) async throws -> LiteLLMUsageSnapshot
    {
        guard let teamID = keyInfo.teamID else {
            throw LiteLLMUsageError.parseFailed("/team/info requested without a team_id")
        }
        let request = self.request(
            url: self.teamInfoURL(baseURL: baseURL, teamID: teamID),
            apiKey: apiKey)
        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LiteLLMUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseTeamInfo(data: response.data, keyInfo: keyInfo, updatedAt: updatedAt)
    }

    private static func request(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func keyInfoURL(baseURL: URL) -> URL {
        self.managementBaseURL(baseURL)
            .appendingPathComponent("key")
            .appendingPathComponent("info")
    }

    private static func userInfoURL(baseURL: URL, userID: String) -> URL {
        self.managementBaseURL(baseURL).appending(
            queryItems: [URLQueryItem(name: "user_id", value: userID)],
            pathComponents: ["user", "info"])
    }

    private static func teamInfoURL(baseURL: URL, teamID: String) -> URL {
        self.managementBaseURL(baseURL).appending(
            queryItems: [URLQueryItem(name: "team_id", value: teamID)],
            pathComponents: ["team", "info"])
    }

    private static func managementBaseURL(_ baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.split(separator: "/").last == "v1" else { return baseURL }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let parts = path.split(separator: "/").dropLast()
        components?.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        return components?.url ?? baseURL
    }

    private static func parseKeyInfo(data: Data) throws -> LiteLLMKeyInfoSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMKeyInfoResponse.self, from: data)
            let userID = self.nonEmpty(decoded.info.userID)
            let teamID = self.nonEmpty(decoded.info.teamID)
            guard userID != nil || teamID != nil else {
                throw LiteLLMUsageError.missingUserID
            }
            return LiteLLMKeyInfoSnapshot(
                userID: userID,
                teamID: teamID,
                keyName: decoded.info.keyName,
                spendUSD: decoded.info.spend ?? 0,
                expiresAt: self.parseDate(decoded.info.expires))
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseUserInfo(
        data: Data,
        keyInfo: LiteLLMKeyInfoSnapshot,
        updatedAt: Date) throws -> LiteLLMUsageSnapshot
    {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMUserInfoResponse.self, from: data)
            guard let expectedUserID = keyInfo.userID else {
                throw LiteLLMUsageError.parseFailed("/user/info requested without a user_id")
            }
            if let responseUserID = decoded.userInfo.userID ?? decoded.userID,
               responseUserID != expectedUserID
            {
                throw LiteLLMUsageError.parseFailed("user_id did not match /key/info")
            }

            let accountEmail = self.firstNonEmpty(
                decoded.userInfo.userEmail,
                decoded.userInfo.userAlias,
                decoded.userInfo.metadata?.preferredUsername)
            let team = self.preferredTeam(from: decoded.teams, keyTeamID: keyInfo.teamID)

            return LiteLLMUsageSnapshot(
                userID: expectedUserID,
                accountEmail: accountEmail,
                personalSpendUSD: decoded.userInfo.spend ?? 0,
                personalBudgetUSD: decoded.userInfo.maxBudget,
                personalResetAt: self.parseDate(decoded.userInfo.budgetResetAt),
                teamUsage: team.map {
                    LiteLLMUsageSnapshot.TeamUsage(
                        id: $0.teamID,
                        alias: $0.teamAlias,
                        spendUSD: $0.spend ?? 0,
                        budgetUSD: $0.maxBudget,
                        resetAt: self.parseDate($0.budgetResetAt),
                        budgetDuration: $0.budgetDuration)
                },
                keyName: keyInfo.keyName,
                keyExpiresAt: keyInfo.expiresAt,
                updatedAt: updatedAt)
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseTeamInfo(
        data: Data,
        keyInfo: LiteLLMKeyInfoSnapshot,
        updatedAt: Date) throws -> LiteLLMUsageSnapshot
    {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMTeamInfoResponse.self, from: data)
            guard let expectedTeamID = keyInfo.teamID else {
                throw LiteLLMUsageError.parseFailed("/team/info requested without a team_id")
            }
            if let responseTeamID = self.firstNonEmpty(decoded.teamInfo.teamID, decoded.teamID),
               responseTeamID != expectedTeamID
            {
                throw LiteLLMUsageError.parseFailed("team_id did not match /key/info")
            }

            let team = decoded.teamInfo
            return LiteLLMUsageSnapshot(
                userID: nil,
                accountEmail: nil,
                personalSpendUSD: 0,
                personalBudgetUSD: nil,
                personalResetAt: nil,
                teamUsage: LiteLLMUsageSnapshot.TeamUsage(
                    id: expectedTeamID,
                    alias: team.teamAlias,
                    spendUSD: team.spend ?? 0,
                    budgetUSD: team.maxBudget,
                    resetAt: self.parseDate(team.budgetResetAt),
                    budgetDuration: team.budgetDuration),
                keyName: keyInfo.keyName,
                keyExpiresAt: keyInfo.expiresAt,
                updatedAt: updatedAt)
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func preferredTeam(
        from teams: [LiteLLMUserInfoResponse.Team]?,
        keyTeamID: String?) -> LiteLLMUserInfoResponse.Team?
    {
        guard let teams, let keyTeamID else { return nil }
        return teams.first(where: { $0.teamID == keyTeamID })
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = self.iso8601DateFormatter(fractionalSeconds: true).date(from: raw) {
            return date
        }
        return self.iso8601DateFormatter(fractionalSeconds: false).date(from: raw)
    }

    private static func iso8601DateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        self.firstNonEmpty(value)
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}

extension URL {
    fileprivate func appending(queryItems: [URLQueryItem], pathComponents: [String]) -> URL {
        let url = pathComponents.reduce(self) { partial, component in
            partial.appendingPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = queryItems
        return components.url ?? url
    }
}
