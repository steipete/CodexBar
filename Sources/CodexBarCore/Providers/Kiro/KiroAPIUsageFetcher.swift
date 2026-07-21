import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct KiroAPIUsageFetcher: Sendable {
    private static let usageAPIKiroVersion = "0.9.2"
    private static let apiRegions = ["us-east-1", "eu-central-1"]
    private static let idcAmzUserAgent =
        "aws-sdk-js/3.738.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.738.0 m/E KiroIDE"
    private static let maxErrorBodyLength = 240

    let credentialStore: KiroCLICredentialStore
    let transport: any ProviderHTTPTransport

    init(
        credentialStore: KiroCLICredentialStore = KiroCLICredentialStore(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func hasCredentials(allowSocial: Bool) -> Bool {
        self.credentialStore.loadCredentials(allowSocial: allowSocial) != nil
    }

    func fetchUsage(allowSocial: Bool) async throws -> KiroUsageSnapshot {
        guard var credentials = self.credentialStore.loadCredentials(allowSocial: allowSocial) else {
            throw KiroAPIError.credentialsNotFound
        }

        if credentials.needsRefresh() {
            credentials = try await self.refreshCredentials(credentials)
        }

        return try await self.fetchUsage(credentials: credentials)
    }

    // MARK: - Token refresh

    private func refreshCredentials(_ credentials: KiroCLICredentials) async throws -> KiroCLICredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }
        guard refreshToken.count >= 100, !refreshToken.contains("...") else {
            throw KiroAPIError.refreshTokenUnavailable
        }

        if credentials.isExternalIDP {
            return try await self.refreshExternalIDPToken(credentials, refreshToken: refreshToken)
        }

        let authMethod = credentials.canonicalAuthMethod
        if authMethod == "idc" {
            return try await self.refreshIDCToken(credentials, refreshToken: refreshToken)
        }
        return try await self.refreshSocialToken(credentials, refreshToken: refreshToken)
    }

    private func refreshSocialToken(
        _ credentials: KiroCLICredentials,
        refreshToken: String) async throws -> KiroCLICredentials
    {
        let region = credentials.effectiveAuthRegion
        let host = "prod.\(region).auth.desktop.kiro.dev"
        guard let url = URL(string: "https://\(host)/refreshToken") else {
            throw KiroAPIError.invalidURL
        }

        let machineID = Self.machineID(for: credentials)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(
            "KiroIDE-\(Self.usageAPIKiroVersion)-\(machineID)",
            forHTTPHeaderField: "User-Agent")
        request.setValue(host, forHTTPHeaderField: "host")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        let response = try await self.transport.response(for: request)
        try Self.validateRefreshResponse(response)

        let json = try Self.decodeJSON(response.data)
        guard let accessToken = Self.string(json, keys: "access_token", "accessToken"), !accessToken.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }

        return credentials.refreshed(
            accessToken: accessToken,
            refreshToken: Self.string(json, keys: "refresh_token", "refreshToken") ?? refreshToken,
            expiresAt: Self.expiresAt(from: json))
    }

    private func refreshIDCToken(
        _ credentials: KiroCLICredentials,
        refreshToken: String) async throws -> KiroCLICredentials
    {
        guard let clientID = credentials.clientID, !clientID.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }
        guard let clientSecret = credentials.clientSecret, !clientSecret.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }

        let region = credentials.effectiveAuthRegion
        let host = "oidc.\(region).amazonaws.com"
        guard let url = URL(string: "https://\(host)/token") else {
            throw KiroAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(Self.idcAmzUserAgent, forHTTPHeaderField: "x-amz-user-agent")
        request.setValue("node", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientID,
            "clientSecret": clientSecret,
            "refreshToken": refreshToken,
            "grantType": "refresh_token",
        ])

        let response = try await self.transport.response(for: request)
        try Self.validateRefreshResponse(response)

        let json = try Self.decodeJSON(response.data)
        guard let accessToken = Self.string(json, keys: "access_token", "accessToken"), !accessToken.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }

        return credentials.refreshed(
            accessToken: accessToken,
            refreshToken: Self.string(json, keys: "refresh_token", "refreshToken") ?? refreshToken,
            expiresAt: Self.expiresAt(from: json))
    }

    private func refreshExternalIDPToken(
        _ credentials: KiroCLICredentials,
        refreshToken: String) async throws -> KiroCLICredentials
    {
        guard let clientID = credentials.clientID, !clientID.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }
        guard let tokenEndpoint = credentials.tokenEndpoint, !tokenEndpoint.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }
        try KiroCLICredentials.validateExternalIDPEndpoint(tokenEndpoint)

        guard let url = URL(string: tokenEndpoint) else {
            throw KiroAPIError.invalidURL
        }

        var bodyComponents = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        if let scopes = credentials.scopes, !scopes.isEmpty {
            bodyComponents.append(URLQueryItem(name: "scope", value: scopes))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyComponents
            .percentEncoded()
            .data(using: .utf8)

        let response = try await self.transport.response(for: request)
        try Self.validateRefreshResponse(response)

        let json = try Self.decodeJSON(response.data)
        guard let accessToken = Self.string(json, keys: "access_token", "accessToken"), !accessToken.isEmpty else {
            throw KiroAPIError.authenticationFailed
        }

        return credentials.refreshed(
            accessToken: accessToken,
            refreshToken: Self.string(json, keys: "refresh_token", "refreshToken") ?? refreshToken,
            expiresAt: Self.expiresAt(from: json))
    }

    // MARK: - Usage fetch

    private func fetchUsage(credentials: KiroCLICredentials) async throws -> KiroUsageSnapshot {
        let regions = Self.regionCandidates(for: credentials.region)
        var lastError: Error?

        for region in regions {
            do {
                return try await self.fetchUsageFromRegion(region: region, credentials: credentials)
            } catch let error as URLError where error.code == .badServerResponse {
                lastError = error
                continue
            } catch {
                throw error
            }
        }

        throw lastError ?? KiroAPIError.allRegionsFailed
    }

    private func fetchUsageFromRegion(
        region: String,
        credentials: KiroCLICredentials) async throws -> KiroUsageSnapshot
    {
        let host = "q.\(region).amazonaws.com"
        let urlString =
            "https://\(host)/getUsageLimits?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST&isEmailRequired=true"
        guard let url = URL(string: urlString) else {
            throw KiroAPIError.invalidURL
        }

        let machineID = Self.machineID(for: credentials)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let userAgent = [
            "aws-sdk-js/1.0.0 ua/2.1 os/macos lang/js md/nodejs#20.0.0",
            "api/codewhispererruntime#1.0.0 m/N,E KiroIDE-\(Self.usageAPIKiroVersion)-\(machineID)",
        ].joined(separator: " ")
        let amzUserAgent = "aws-sdk-js/1.0.0 KiroIDE-\(Self.usageAPIKiroVersion)-\(machineID)"

        request.setValue(amzUserAgent, forHTTPHeaderField: "x-amz-user-agent")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue(host, forHTTPHeaderField: "host")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "amz-sdk-invocation-id")
        request.setValue("attempt=1; max=1", forHTTPHeaderField: "amz-sdk-request")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let tokenType = credentials.tokenTypeHeader {
            request.setValue(tokenType, forHTTPHeaderField: "tokentype")
        }

        let response = try await self.transport.response(
            for: request,
            retryPolicy: .transientIdempotent)

        switch response.statusCode {
        case 200:
            let usageResponse = try JSONDecoder().decode(KiroUsageLimitsResponse.self, from: response.data)
            return try usageResponse.toSnapshot()
        case 403:
            throw URLError(.badServerResponse)
        case 401:
            throw KiroAPIError.authenticationFailed
        case 429:
            throw KiroAPIError.rateLimited
        default:
            throw KiroAPIError.httpError(
                statusCode: response.statusCode,
                summary: Self.sanitizedResponseBodySummary(response.data))
        }
    }

    // MARK: - Helpers

    private static func regionCandidates(for ssoRegion: String?) -> [String] {
        guard let ssoRegion else { return self.apiRegions }
        if ssoRegion == "eu-central-1" || ssoRegion.hasPrefix("eu-") {
            return ["eu-central-1", "us-east-1"]
        }
        return self.apiRegions
    }

    static func machineID(for credentials: KiroCLICredentials) -> String {
        if let configured = credentials.machineID,
           let normalized = normalizeMachineID(configured)
        {
            return normalized
        }
        if let refreshToken = credentials.refreshToken, !refreshToken.isEmpty {
            return Self.sha256Hex("KotlinNativeAPI/\(refreshToken)")
        }
        return Self.sha256Hex("KiroFallback/\(credentials.storageKey)")
    }

    static func normalizeMachineID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) {
            return trimmed.lowercased()
        }
        let withoutDashes = trimmed.filter { $0 != "-" }
        if withoutDashes.count == 32, withoutDashes.allSatisfy(\.isHexDigit) {
            return String(repeating: withoutDashes.lowercased(), count: 2)
        }
        return nil
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validateRefreshResponse(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 400 where String(data: response.data, encoding: .utf8)?.contains("invalid_grant") == true:
            throw KiroAPIError.refreshTokenExpired
        case 401:
            throw KiroAPIError.authenticationFailed
        case 429:
            throw KiroAPIError.rateLimited
        default:
            throw KiroAPIError.httpError(
                statusCode: response.statusCode,
                summary: self.sanitizedResponseBodySummary(response.data))
        }
    }

    private static func decodeJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KiroAPIError.invalidResponse
        }
        return json
    }

    private static func string(_ json: [String: Any], keys: String...) -> String? {
        for key in keys {
            guard let value = json[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func expiresAt(from json: [String: Any]) -> Date? {
        if let expiresIn = json["expires_in"] as? Int ?? json["expiresIn"] as? Int {
            return Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        if let expiresIn = json["expires_in"] as? Double ?? json["expiresIn"] as? Double {
            return Date().addingTimeInterval(expiresIn)
        }
        if let expiresAt = self.string(json, keys: "expires_at", "expiresAt") {
            return Self.parseISO8601Date(expiresAt)
        }
        return nil
    }

    static func sanitizedResponseBodySummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }
        guard let rawBody = String(data: data, encoding: .utf8) else {
            return "non-text body (\(data.count) bytes)"
        }

        let body = Self.redactSensitiveBodyContent(rawBody)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "non-text body (\(data.count) bytes)" }
        guard body.count > Self.maxErrorBodyLength else { return body }
        let index = body.index(body.startIndex, offsetBy: Self.maxErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }

    private static func redactSensitiveBodyContent(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (
                #"(?i)(\"(?:api_?key|authorization|token|access_token|refresh_token)\"\s*:\s*\")([^\"]+)(\")"#,
                "$1[REDACTED]$3"),
            (
                #"(?i)((?:api_?key|authorization|token|access_token|refresh_token)\s*[=:]\s*)([^,\s]+)"#,
                "$1[REDACTED]"),
        ]
        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression)
        }
    }

    #if DEBUG
    static func _machineIDForTesting(_ credentials: KiroCLICredentials) -> String {
        self.machineID(for: credentials)
    }

    static func _sanitizedResponseBodySummaryForTesting(_ body: String) -> String {
        self.sanitizedResponseBodySummary(Data(body.utf8))
    }
    #endif
}

extension KiroCLICredentials {
    fileprivate func refreshed(accessToken: String, refreshToken: String, expiresAt: Date?) -> KiroCLICredentials {
        KiroCLICredentials(
            storageKey: self.storageKey,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            region: self.region,
            authRegion: self.authRegion,
            startURL: self.startURL,
            tokenEndpoint: self.tokenEndpoint,
            scopes: self.scopes,
            clientID: self.clientID,
            clientSecret: self.clientSecret,
            authMethod: self.authMethod,
            provider: self.provider,
            machineID: self.machineID)
    }
}

extension [URLQueryItem] {
    fileprivate func percentEncoded() -> String {
        var components = URLComponents()
        components.queryItems = self
        return components.percentEncodedQuery ?? ""
    }
}

extension Character {
    fileprivate var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}

enum KiroAPIError: Error, LocalizedError, Equatable {
    case credentialsNotFound
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case refreshTokenUnavailable
    case refreshTokenExpired
    case rateLimited
    case allRegionsFailed
    case invalidExternalIDPEndpoint
    case httpError(statusCode: Int, summary: String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            "Kiro credentials not found. Please run 'kiro-cli login' first."
        case .invalidURL:
            "Invalid Kiro API URL"
        case .invalidResponse:
            "Invalid response from Kiro API"
        case .authenticationFailed:
            "Kiro authentication failed. Please run 'kiro-cli login' again."
        case .refreshTokenUnavailable:
            "Kiro refresh token is unavailable. Please run 'kiro-cli login' again."
        case .refreshTokenExpired:
            "Kiro session expired. Please run 'kiro-cli login' again."
        case .rateLimited:
            "Kiro API rate limited. Please try again later."
        case .allRegionsFailed:
            "All Kiro API regions failed"
        case .invalidExternalIDPEndpoint:
            "Kiro external IdP endpoint is not allowed"
        case let .httpError(statusCode, summary):
            "Kiro API error (\(statusCode)): \(summary)"
        }
    }
}

// MARK: - API Response Models

struct KiroUsageLimitsResponse: Decodable {
    let nextDateReset: KiroFlexibleResetDate?
    let subscriptionInfo: KiroSubscriptionInfo?
    let usageBreakdownList: [KiroUsageBreakdown]?
    let overageConfiguration: KiroOverageConfiguration?
    let userInfo: KiroUserInfo?

    func toSnapshot() throws -> KiroUsageSnapshot {
        let planName = self.subscriptionInfo?.subscriptionTitle ?? "KIRO FREE"
        let email = self.userInfo?.email

        guard let breakdown = self.usageBreakdownList?.first else {
            return KiroUsageSnapshot(
                planName: planName,
                displayPlanName: KiroStatusProbe.displayPlanName(planName),
                accountEmail: email,
                authMethod: nil,
                creditsUsed: 0,
                creditsTotal: 0,
                creditsPercent: 0,
                bonusCreditsUsed: nil,
                bonusCreditsTotal: nil,
                bonusExpiryDays: nil,
                overagesStatus: self.overageConfiguration?.overageStatus,
                overageCreditsUsed: nil,
                estimatedOverageCostUSD: nil,
                manageURL: nil,
                contextUsage: nil,
                resetsAt: self.nextDateReset?.date,
                updatedAt: Date())
        }

        let creditsUsed = breakdown.currentUsageWithPrecision ?? Double(breakdown.currentUsage ?? 0)
        let creditsTotal = breakdown.usageLimitWithPrecision ?? Double(breakdown.usageLimit ?? 0)
        let creditsPercent = creditsTotal > 0 ? (creditsUsed / creditsTotal) * 100.0 : 0

        var bonusUsed: Double?
        var bonusTotal: Double?
        let activeBonuses = (breakdown.bonuses ?? []).filter { $0.status == "ACTIVE" }
        if !activeBonuses.isEmpty {
            bonusUsed = activeBonuses.reduce(0) { $0 + ($1.currentUsage ?? 0) }
            bonusTotal = activeBonuses.reduce(0) { $0 + ($1.usageLimit ?? 0) }
        }

        return KiroUsageSnapshot(
            planName: planName,
            displayPlanName: KiroStatusProbe.displayPlanName(planName),
            accountEmail: email,
            authMethod: nil,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsPercent: creditsPercent,
            bonusCreditsUsed: bonusUsed,
            bonusCreditsTotal: bonusTotal,
            bonusExpiryDays: nil,
            overagesStatus: self.overageConfiguration?.overageStatus,
            overageCreditsUsed: nil,
            estimatedOverageCostUSD: nil,
            manageURL: nil,
            contextUsage: nil,
            resetsAt: self.nextDateReset?.date,
            updatedAt: Date())
    }
}

struct KiroFlexibleResetDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.date = nil
            return
        }
        if let timestamp = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: timestamp)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self.date = KiroAPIUsageFetcher.parseISO8601Date(stringValue)
            return
        }
        self.date = nil
    }
}

struct KiroSubscriptionInfo: Decodable {
    let subscriptionTitle: String?
    let overageCapability: String?
}

struct KiroUsageBreakdown: Decodable {
    let currentUsage: Int?
    let currentUsageWithPrecision: Double?
    let usageLimit: Int?
    let usageLimitWithPrecision: Double?
    let bonuses: [KiroBonus]?
    let freeTrialInfo: KiroFreeTrialInfo?

    enum CodingKeys: String, CodingKey {
        case currentUsage
        case currentUsageWithPrecision
        case usageLimit
        case usageLimitWithPrecision
        case bonuses
        case freeTrialInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentUsage = try container.decodeIfPresent(Int.self, forKey: .currentUsage)
        self.currentUsageWithPrecision = try container.decodeIfPresent(Double.self, forKey: .currentUsageWithPrecision)
        self.usageLimit = try container.decodeIfPresent(Int.self, forKey: .usageLimit)
        self.usageLimitWithPrecision = try container.decodeIfPresent(Double.self, forKey: .usageLimitWithPrecision)
        self.bonuses = try container.decodeIfPresent([KiroBonus].self, forKey: .bonuses)
        self.freeTrialInfo = try container.decodeIfPresent(KiroFreeTrialInfo.self, forKey: .freeTrialInfo)
    }
}

struct KiroBonus: Decodable {
    let currentUsage: Double?
    let usageLimit: Double?
    let status: String?
}

struct KiroFreeTrialInfo: Decodable {
    let currentUsage: Int?
    let currentUsageWithPrecision: Double?
    let usageLimit: Int?
    let usageLimitWithPrecision: Double?
    let freeTrialExpiry: Double?
    let freeTrialStatus: String?
}

struct KiroOverageConfiguration: Decodable {
    let overageEnabled: Bool?
    let overageStatus: String?
}

struct KiroUserInfo: Decodable {
    let email: String?
}

extension KiroAPIUsageFetcher {
    static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
