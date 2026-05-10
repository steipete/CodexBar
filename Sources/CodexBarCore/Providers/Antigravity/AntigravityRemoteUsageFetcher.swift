import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityRemoteFetchError: LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case permissionDenied(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Antigravity Google auth not found. Use Antigravity login to authenticate."
        case let .permissionDenied(message):
            "Antigravity remote API permission denied: \(message)"
        case let .apiError(message):
            "Antigravity remote API error: \(message)"
        case let .parseFailed(message):
            "Could not parse Antigravity remote usage: \(message)"
        }
    }
}

public struct AntigravityRemoteUsageFetcher: Sendable {
    public var timeout: TimeInterval = 10.0
    public var homeDirectory: String
    public var dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public var oauthClientResolver: @Sendable () -> AntigravityOAuthClient?

    private static let log = CodexBarLog.logger(LogCategories.antigravity)
    private static let userAgent = "antigravity"
    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let loadCodeAssistEndpoint = "\(baseURL)/v1internal:loadCodeAssist"
    private static let onboardUserEndpoint = "\(baseURL)/v1internal:onboardUser"
    private static let fetchAvailableModelsEndpoint = "\(baseURL)/v1internal:fetchAvailableModels"
    private static let retrieveUserQuotaEndpoint = "\(baseURL)/v1internal:retrieveUserQuota"
    private static let refreshSafetyWindow: TimeInterval = 60

    private struct FetchContext {
        let timeout: TimeInterval
        let store: AntigravityOAuthCredentialsStore
        let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        let oauthClientResolver: @Sendable () -> AntigravityOAuthClient?
    }

    public init(
        timeout: TimeInterval = 10.0,
        homeDirectory: String = NSHomeDirectory(),
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
        oauthClientResolver: @escaping @Sendable () -> AntigravityOAuthClient? = {
            AntigravityOAuthConfig.resolvedClient()
        })
    {
        self.timeout = timeout
        self.homeDirectory = homeDirectory
        self.dataLoader = dataLoader
        self.oauthClientResolver = oauthClientResolver
    }

    public func fetch() async throws -> AntigravityStatusSnapshot {
        let source = try Self.resolveCredentialSource(homeDirectory: self.homeDirectory)
        let store = source.primaryStore
        guard let credentials = source.credentials else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }
        return try await Self.fetchSnapshot(
            using: credentials,
            timeout: self.timeout,
            store: store,
            dataLoader: self.dataLoader,
            oauthClientResolver: self.oauthClientResolver)
    }

    private static func fetchSnapshot(
        using initialCredentials: AntigravityOAuthCredentials,
        timeout: TimeInterval,
        store: AntigravityOAuthCredentialsStore,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        oauthClientResolver: @escaping @Sendable () -> AntigravityOAuthClient?) async throws
        -> AntigravityStatusSnapshot
    {
        guard let storedAccessToken = initialCredentials.accessToken?.trimmedNonEmpty else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }

        var credentials = initialCredentials
        var accessToken = storedAccessToken
        let context = FetchContext(
            timeout: timeout,
            store: store,
            dataLoader: dataLoader,
            oauthClientResolver: oauthClientResolver)
        if Self.shouldRefresh(expiryDate: credentials.expiryDate, now: Date()) {
            guard let refreshToken = credentials.refreshToken?.trimmedNonEmpty else {
                throw AntigravityRemoteFetchError.notLoggedIn
            }
            accessToken = try await Self.refreshAccessToken(
                credentials: credentials,
                refreshToken: refreshToken,
                context: context)
            credentials = try store.load() ?? credentials
            credentials.accessToken = credentials.accessToken?.trimmedNonEmpty ?? accessToken
        }

        let claims = Self.extractClaims(from: credentials)
        let codeAssist = try await Self.loadCodeAssist(
            accessToken: accessToken,
            timeout: timeout,
            dataLoader: dataLoader)
        let projectId = try await Self.resolveProjectID(
            accessToken: accessToken,
            storedProjectID: credentials.projectID?.trimmedNonEmpty,
            initialResponse: codeAssist,
            context: context)
        let models = try await Self.fetchModelQuotas(
            accessToken: accessToken,
            projectId: projectId,
            timeout: timeout,
            dataLoader: dataLoader)

        return AntigravityStatusSnapshot(
            modelQuotas: models,
            accountEmail: claims.email,
            accountPlan: Self.resolvePlan(response: codeAssist, claims: claims))
    }

    private static func shouldRefresh(expiryDate: Date?, now: Date) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate.timeIntervalSince(now) <= Self.refreshSafetyWindow
    }

    private static func loadCodeAssist(
        accessToken: String,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> CodeAssistResponse
    {
        let body = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        return try await Self.sendRequest(
            endpoint: Self.loadCodeAssistEndpoint,
            accessToken: accessToken,
            body: body,
            timeout: timeout,
            dataLoader: dataLoader)
    }

    private static func fetchAvailableModels(
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> FetchAvailableModelsResponse
    {
        let body: [String: Any] = if let projectId = projectId?.trimmedNonEmpty {
            ["project": projectId]
        } else {
            [:]
        }
        return try await Self.sendRequest(
            endpoint: Self.fetchAvailableModelsEndpoint,
            accessToken: accessToken,
            body: body,
            timeout: timeout,
            dataLoader: dataLoader)
    }

    private static func fetchModelQuotas(
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> [AntigravityModelQuota]
    {
        do {
            let response = try await Self.fetchAvailableModels(
                accessToken: accessToken,
                projectId: projectId,
                timeout: timeout,
                dataLoader: dataLoader)
            return try Self.parseModelQuotas(response)
        } catch let error as AntigravityRemoteFetchError {
            guard case .permissionDenied = error else {
                throw error
            }
            Self.log.info("Falling back to retrieveUserQuota for Antigravity remote usage")
            do {
                let response = try await Self.retrieveUserQuota(
                    accessToken: accessToken,
                    projectId: projectId,
                    timeout: timeout,
                    dataLoader: dataLoader)
                return try Self.parseQuotaBuckets(response)
            } catch let quotaError as AntigravityRemoteFetchError {
                guard case .permissionDenied = quotaError else {
                    throw quotaError
                }
                Self.log.info("Antigravity remote quota endpoints are not permitted for this account")
                return []
            }
        }
    }

    private static func retrieveUserQuota(
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> RetrieveUserQuotaResponse
    {
        let body: [String: Any] = if let projectId = projectId?.trimmedNonEmpty {
            ["project": projectId]
        } else {
            [:]
        }
        return try await Self.sendRequest(
            endpoint: Self.retrieveUserQuotaEndpoint,
            accessToken: accessToken,
            body: body,
            timeout: timeout,
            dataLoader: dataLoader)
    }

    private static func resolveProjectID(
        accessToken: String,
        storedProjectID: String?,
        initialResponse: CodeAssistResponse,
        context: FetchContext) async throws
        -> String?
    {
        if let storedProjectID {
            return storedProjectID
        }

        if let projectID = initialResponse.projectID {
            try? Self.updateStoredProjectID(projectID, store: context.store)
            return projectID
        }

        guard let tierID = Self.pickOnboardTier(from: initialResponse) else {
            return nil
        }

        let onboardBody: [String: Any] = [
            "tierId": tierID,
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]

        do {
            let onboardResponse: OnboardResponse = try await Self.sendRequest(
                endpoint: Self.onboardUserEndpoint,
                accessToken: accessToken,
                body: onboardBody,
                timeout: context.timeout,
                dataLoader: context.dataLoader)
            if let projectID = onboardResponse.projectID {
                try? Self.updateStoredProjectID(projectID, store: context.store)
                return projectID
            }
        } catch {
            Self.log.warning("Antigravity onboarding request failed", metadata: [
                "error": "\(error.localizedDescription)",
            ])
        }

        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(2000))
            let refreshed = try await Self.loadCodeAssist(
                accessToken: accessToken,
                timeout: context.timeout,
                dataLoader: context.dataLoader)
            if let projectID = refreshed.projectID {
                try? Self.updateStoredProjectID(projectID, store: context.store)
                return projectID
            }
        }

        return nil
    }

    private static func sendRequest<Response: Decodable>(
        endpoint: String,
        accessToken: String,
        body: [String: Any],
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> Response
    {
        guard let url = URL(string: endpoint) else {
            throw AntigravityRemoteFetchError.apiError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityRemoteFetchError.apiError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AntigravityRemoteFetchError.notLoggedIn
        case 403:
            let message = String(data: data, encoding: .utf8)?.trimmedNonEmpty ?? "HTTP 403"
            throw AntigravityRemoteFetchError.permissionDenied(message)
        default:
            let message = String(data: data, encoding: .utf8)?.trimmedNonEmpty ?? "HTTP \(httpResponse.statusCode)"
            throw AntigravityRemoteFetchError.apiError("HTTP \(httpResponse.statusCode): \(message)")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AntigravityRemoteFetchError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseModelQuotas(_ response: FetchAvailableModelsResponse) throws -> [AntigravityModelQuota] {
        let models = response.models ?? [:]
        return models.compactMap { modelID, model in
            guard let quotaInfo = model.quotaInfo else { return nil }
            let resetTime = quotaInfo.resetTime.flatMap(Self.parseResetTime(_:))
            let label = model.displayName?.trimmedNonEmpty
                ?? model.label?.trimmedNonEmpty
                ?? modelID
            return AntigravityModelQuota(
                label: label,
                modelId: modelID,
                remainingFraction: quotaInfo.remainingFraction,
                resetTime: resetTime,
                resetDescription: resetTime.map { UsageFormatter.resetDescription(from: $0) })
        }
    }

    private static func parseQuotaBuckets(_ response: RetrieveUserQuotaResponse) throws -> [AntigravityModelQuota] {
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw AntigravityRemoteFetchError.parseFailed("No quota buckets in response")
        }

        var modelQuotaMap: [String: (fraction: Double?, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId?.trimmedNonEmpty else { continue }
            let next = (bucket.remainingFraction, bucket.resetTime)
            if let existing = modelQuotaMap[modelID] {
                let existingValue = existing.fraction ?? Double.greatestFiniteMagnitude
                let nextValue = next.0 ?? Double.greatestFiniteMagnitude
                if nextValue < existingValue {
                    modelQuotaMap[modelID] = next
                }
            } else {
                modelQuotaMap[modelID] = next
            }
        }

        return modelQuotaMap.keys.sorted().compactMap { modelID in
            guard let info = modelQuotaMap[modelID] else { return nil }
            let resetTime = info.resetTime.flatMap(Self.parseResetTime(_:))
            return AntigravityModelQuota(
                label: modelID,
                modelId: modelID,
                remainingFraction: info.fraction,
                resetTime: resetTime,
                resetDescription: resetTime.map { UsageFormatter.resetDescription(from: $0) })
        }
    }

    private static func resolvePlan(response: CodeAssistResponse, claims: TokenClaims) -> String? {
        if let planType = response.planInfo?.planType?.trimmedNonEmpty {
            return planType
        }

        switch (response.currentTier?.id?.trimmedNonEmpty, claims.hostedDomain) {
        case ("standard-tier", _):
            return "Paid"
        case ("free-tier", .some):
            return "Workspace"
        case ("free-tier", .none):
            return "Free"
        case ("legacy-tier", _):
            return "Legacy"
        default:
            return response.currentTier?.name?.trimmedNonEmpty
        }
    }

    private static func pickOnboardTier(from response: CodeAssistResponse) -> String? {
        if let defaultTier = response.allowedTiers?
            .first(where: { $0.isDefault == true && $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
        {
            return defaultTier
        }
        if let firstTier = response.allowedTiers?
            .first(where: { $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
        {
            return firstTier
        }
        if let paidTier = response.paidTier?.id?.trimmedNonEmpty {
            return paidTier
        }
        if let currentTier = response.currentTier?.id?.trimmedNonEmpty {
            return currentTier
        }
        return nil
    }

    private static func parseResetTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func credentialsStore(homeDirectory: String) -> AntigravityOAuthCredentialsStore {
        let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        return AntigravityOAuthCredentialsStore(fileURL: AntigravityOAuthCredentialsStore.defaultURL(home: homeURL))
    }

    private static func resolveCredentialSource(homeDirectory: String) throws -> (
        credentials: AntigravityOAuthCredentials?,
        primaryStore: AntigravityOAuthCredentialsStore)
    {
        let primaryStore = Self.credentialsStore(homeDirectory: homeDirectory)
        return try (primaryStore.load(), primaryStore)
    }

    private static func refreshAccessToken(
        credentials: AntigravityOAuthCredentials,
        refreshToken: String,
        context: FetchContext) async throws
        -> String
    {
        let oauthClient = try Self.refreshOAuthClient(
            from: credentials,
            oauthClientResolver: context.oauthClientResolver)

        var request = URLRequest(url: AntigravityOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = context.timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": oauthClient.clientID,
            "client_secret": oauthClient.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let (data, response) = try await context.dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityRemoteFetchError.apiError("Invalid refresh response")
        }
        guard httpResponse.statusCode == 200 else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw AntigravityRemoteFetchError.parseFailed("Could not parse refresh response")
        }

        try Self.updateStoredCredentials(json, store: context.store)
        return accessToken
    }

    private static func refreshOAuthClient(
        from credentials: AntigravityOAuthCredentials,
        oauthClientResolver: @escaping @Sendable () -> AntigravityOAuthClient?) throws
        -> AntigravityOAuthClient
    {
        if let clientID = credentials.clientID?.trimmedNonEmpty,
           let clientSecret = credentials.clientSecret?.trimmedNonEmpty
        {
            return AntigravityOAuthClient(clientID: clientID, clientSecret: clientSecret)
        }

        guard let client = oauthClientResolver() else {
            throw AntigravityRemoteFetchError.apiError(AntigravityOAuthConfig.missingCredentialsMessage)
        }
        return client
    }

    private static func updateStoredCredentials(
        _ refreshResponse: [String: Any],
        store: AntigravityOAuthCredentialsStore) throws
    {
        guard var credentials = try store.load() else { return }
        if let accessToken = refreshResponse["access_token"] as? String {
            credentials.accessToken = accessToken
        }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            credentials.expiryDateMilliseconds = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        if let expiresIn = refreshResponse["expires_in"] as? Int {
            credentials.expiryDateMilliseconds = (Date().timeIntervalSince1970 + Double(expiresIn)) * 1000
        }
        if let idToken = refreshResponse["id_token"] as? String {
            credentials.idToken = idToken
        }
        try store.save(credentials)
    }

    private static func updateStoredProjectID(_ projectID: String, store: AntigravityOAuthCredentialsStore) throws {
        guard var credentials = try store.load() else { return }
        guard credentials.projectID?.trimmedNonEmpty != projectID else { return }
        credentials.projectID = projectID
        try store.save(credentials)
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { key, value in
            URLQueryItem(name: key, value: value)
        }
        return components.query?.data(using: .utf8)
    }

    private struct TokenClaims {
        let email: String?
        let hostedDomain: String?
    }

    private static func extractClaims(from credentials: AntigravityOAuthCredentials) -> TokenClaims {
        let tokenClaims = Self.extractClaimsFromToken(credentials.idToken)
        return TokenClaims(
            email: tokenClaims.email ?? credentials.email?.trimmedNonEmpty,
            hostedDomain: tokenClaims.hostedDomain)
    }

    private static func extractClaimsFromToken(_ idToken: String?) -> TokenClaims {
        guard let idToken else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }

        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }

        return TokenClaims(
            email: (json["email"] as? String)?.trimmedNonEmpty,
            hostedDomain: (json["hd"] as? String)?.trimmedNonEmpty)
    }
}

extension String {
    fileprivate var trimmedNonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ProjectReference: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let stringValue = try? single.decode(String.self) {
            self.value = stringValue
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try keyed.decodeIfPresent(String.self, forKey: .id)
            ?? keyed.decodeIfPresent(String.self, forKey: .projectID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID = "projectId"
    }
}

private struct CodeAssistResponse: Decodable {
    let planInfo: CodeAssistPlanInfo?
    let currentTier: TierInfo?
    let paidTier: TierInfo?
    let allowedTiers: [AllowedTier]?
    let cloudaicompanionProject: ProjectReference?

    var projectID: String? {
        self.cloudaicompanionProject?.value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct CodeAssistPlanInfo: Decodable {
    let planType: String?
}

private struct TierInfo: Decodable {
    let id: String?
    let name: String?
}

private struct AllowedTier: Decodable {
    let id: String?
    let isDefault: Bool?
}

private struct OnboardResponse: Decodable {
    let response: OnboardInnerResponse?

    var projectID: String? {
        self.response?.cloudaicompanionProject?.value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct OnboardInnerResponse: Decodable {
    let cloudaicompanionProject: ProjectReference?
}

private struct FetchAvailableModelsResponse: Decodable {
    let models: [String: AntigravityRemoteModel]?
}

private struct RetrieveUserQuotaResponse: Decodable {
    let buckets: [RetrieveUserQuotaBucket]?
}

private struct RetrieveUserQuotaBucket: Decodable {
    let modelId: String?
    let remainingFraction: Double?
    let resetTime: String?
}

private struct AntigravityRemoteModel: Decodable {
    let displayName: String?
    let label: String?
    let quotaInfo: AntigravityRemoteQuotaInfo?
}

private struct AntigravityRemoteQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

extension String? {
    fileprivate var trimmedNonEmpty: String? {
        self?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
