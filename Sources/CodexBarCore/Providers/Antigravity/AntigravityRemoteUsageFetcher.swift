import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityRemoteFetchError: LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case reauthenticationRequired
    case permissionDenied(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Antigravity Google auth not found. Use Antigravity login to authenticate."
        case .reauthenticationRequired:
            "This Antigravity account was signed in with an OAuth client that cannot read its quota. "
                + "Sign in to it again."
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
    @ProcessEnvironment public var environment: [String: String]
    public var dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public var oauthClientResolver: @Sendable () -> AntigravityOAuthClient?
    public var credentialsUpdateHandler: @Sendable (AntigravityOAuthCredentials) async throws -> Void

    private static let log = CodexBarLog.logger(LogCategories.provider(.antigravity))
    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let loadCodeAssistEndpoint = "\(baseURL)/v1internal:loadCodeAssist"
    private static let onboardUserEndpoint = "\(baseURL)/v1internal:onboardUser"
    private static let refreshSafetyWindow: TimeInterval = 60
    private static let clientMetadata = [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    ]

    /// Cloud Code requires the Hub client family for quota access; pin a shared compatibility identity.
    private static let userAgent: String = {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        #if os(Linux)
        let platform = "linux"
        #else
        let platform = "darwin"
        #endif
        return "antigravity/hub/2.9.1 \(platform)/\(architecture)"
    }()

    private struct FetchContext {
        let timeout: TimeInterval
        let store: AntigravityOAuthCredentialsStore?
        let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        let oauthClientResolver: @Sendable () -> AntigravityOAuthClient?
        let credentialsUpdateHandler: @Sendable (AntigravityOAuthCredentials) async throws -> Void

        func persistCredentials(_ credentials: AntigravityOAuthCredentials) async throws {
            if let store {
                try store.save(credentials)
            } else {
                try await self.credentialsUpdateHandler(credentials)
            }
        }
    }

    public init(
        timeout: TimeInterval = 10.0,
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await ProviderHTTPClient.shared.data(for: request)
        },
        oauthClientResolver: @escaping @Sendable () -> AntigravityOAuthClient? = {
            AntigravityOAuthConfig.resolvedClient()
        },
        credentialsUpdateHandler: @escaping @Sendable (AntigravityOAuthCredentials) async throws -> Void = { _ in })
    {
        self.timeout = timeout
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.dataLoader = dataLoader
        self.oauthClientResolver = oauthClientResolver
        self.credentialsUpdateHandler = credentialsUpdateHandler
    }

    public func fetch() async throws -> AntigravityStatusSnapshot {
        let source = try Self.resolveCredentialSource(homeDirectory: self.homeDirectory, environment: self.environment)
        guard let initialCredentials = source.credentials else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }
        let store = source.store
        guard let storedAccessToken = initialCredentials.accessToken?.trimmedNonEmpty else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }

        var credentials = initialCredentials
        var accessToken = storedAccessToken
        let context = FetchContext(
            timeout: self.timeout,
            store: store,
            dataLoader: self.dataLoader,
            oauthClientResolver: self.oauthClientResolver,
            credentialsUpdateHandler: self.credentialsUpdateHandler)
        if let expiryDate = credentials.expiryDate, expiryDate.timeIntervalSinceNow <= Self.refreshSafetyWindow {
            guard let refreshToken = credentials.refreshToken?.trimmedNonEmpty else {
                throw AntigravityRemoteFetchError.notLoggedIn
            }
            let refreshed = try await Self.refreshAccessToken(
                credentials: credentials,
                refreshToken: refreshToken,
                context: context)
            accessToken = refreshed.accessToken
            credentials = refreshed.credentials
            if let store {
                credentials = try store.load() ?? credentials
            }
            credentials.accessToken = credentials.accessToken?.trimmedNonEmpty ?? accessToken
        }

        let claims = Self.extractClaims(from: credentials)
        let codeAssist = try await Self.loadCodeAssist(
            accessToken: accessToken,
            timeout: self.timeout,
            dataLoader: self.dataLoader)
        if credentials.projectID?.trimmedNonEmpty == nil, codeAssist.rejectsClientForConsumerTier {
            // Quota endpoints would answer with a placeholder summary that reports every bucket at 100%.
            throw AntigravityRemoteFetchError.reauthenticationRequired
        }
        let projectId = try await Self.resolveProjectID(
            accessToken: accessToken,
            storedProjectID: credentials.projectID?.trimmedNonEmpty,
            initialResponse: codeAssist,
            context: context)
        if let projectId, credentials.projectID?.trimmedNonEmpty != projectId {
            credentials.projectID = projectId
            do {
                try await context.persistCredentials(credentials)
            } catch {
                Self.log.warning("Could not persist Antigravity project ID: \(error.localizedDescription)")
            }
        }
        let plan = Self.resolvePlan(response: codeAssist, claims: claims)
        let accountMetadata = Self.resolveAccountMetadata(from: codeAssist)
        let credits = Self.resolveCredits(from: codeAssist)
        do {
            let response: AntigravityQuotaSummaryResponse = try await Self.fetchQuotaResponse(
                endpoint: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                accessToken: accessToken,
                projectId: projectId,
                timeout: min(self.timeout, 2),
                dataLoader: self.dataLoader)
            try Task.checkCancellation()
            let summary = try response.snapshot(
                accountEmail: claims.email,
                accountPlan: plan,
                source: .remote,
                credits: credits,
                accountMetadata: accountMetadata)
            if summary.hasKnownQuotaSummary {
                let modelCatalog = try await Self.fetchModelCatalogBestEffort(
                    accessToken: accessToken,
                    projectId: projectId,
                    timeout: min(self.timeout, 2),
                    dataLoader: self.dataLoader)
                let enrichedSummary = summary.withModelCatalog(modelCatalog)
                if plan?.lowercased() == "free",
                   try enrichedSummary.toUsageSnapshot().extraRateWindows?.contains(where: {
                       $0.usageKnown && $0.window.windowMinutes == 300
                   }) == true
                {
                    return try response.snapshot(
                        accountEmail: claims.email,
                        source: .remote,
                        credits: credits,
                        accountMetadata: accountMetadata)
                        .withModelCatalog(modelCatalog)
                }
                return enrichedSummary
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled ||
                (error as? AntigravityRemoteFetchError) == .notLoggedIn
            {
                throw error
            }
            try Task.checkCancellation()
        }
        let (models, catalog) = try await Self.fetchModelQuotas(
            accessToken: accessToken,
            projectId: projectId,
            timeout: self.timeout,
            dataLoader: self.dataLoader)

        return AntigravityStatusSnapshot(
            modelQuotas: models,
            accountEmail: claims.email,
            accountPlan: plan,
            source: .remote,
            credits: credits,
            accountMetadata: accountMetadata,
            modelCatalog: catalog)
    }

    private static func loadCodeAssist(
        accessToken: String,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> CodeAssistResponse
    {
        try await self.sendRequest(
            endpoint: self.loadCodeAssistEndpoint,
            accessToken: accessToken,
            body: ["metadata": self.clientMetadata],
            timeout: timeout,
            dataLoader: dataLoader)
    }

    private static func fetchQuotaResponse<Response: Decodable>(
        endpoint: String,
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> Response
    {
        let body: [String: Any] = (projectId?.trimmedNonEmpty).map { ["project": $0] } ?? [:]
        return try await Self.sendRequest(
            endpoint: endpoint,
            accessToken: accessToken,
            body: body,
            timeout: timeout,
            dataLoader: dataLoader)
    }

    private static func fetchModelCatalogBestEffort(
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> [AntigravityModelCatalogEntry]
    {
        do {
            let response: FetchAvailableModelsResponse = try await Self.fetchQuotaResponse(
                endpoint: "\(Self.baseURL)/v1internal:fetchAvailableModels",
                accessToken: accessToken,
                projectId: projectId,
                timeout: timeout,
                dataLoader: dataLoader)
            try Task.checkCancellation()
            return Self.parseModelCatalog(response)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            try Task.checkCancellation()
            return []
        }
    }

    private static func fetchModelQuotas(
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> (quotas: [AntigravityModelQuota], catalog: [AntigravityModelCatalogEntry])
    {
        do {
            let response: FetchAvailableModelsResponse = try await Self.fetchQuotaResponse(
                endpoint: "\(Self.baseURL)/v1internal:fetchAvailableModels",
                accessToken: accessToken,
                projectId: projectId,
                timeout: timeout,
                dataLoader: dataLoader)
            let catalog = Self.parseModelCatalog(response)
            let modelQuotas = try Self.parseModelQuotas(response)
            if Self.shouldVerifyFullRemoteQuotas(modelQuotas) {
                let quotaBuckets = try await Self.fetchQuotaBucketsIfPermitted(
                    accessToken: accessToken,
                    projectId: projectId,
                    timeout: timeout,
                    dataLoader: dataLoader)
                guard let quotaBuckets, quotaBuckets.contains(where: { $0.remainingFraction != nil }) else {
                    return ([], catalog)
                }
                return (Self.mergeVerifiedQuotas(modelQuotas: modelQuotas, verifiedQuotas: quotaBuckets), catalog)
            }
            return (modelQuotas, catalog)
        } catch let error as AntigravityRemoteFetchError {
            guard case .permissionDenied = error else {
                throw error
            }
            Self.log.info("Falling back to retrieveUserQuota for Antigravity remote usage")
            let buckets = try await Self.fetchQuotaBucketsIfPermitted(
                accessToken: accessToken,
                projectId: projectId,
                timeout: timeout,
                dataLoader: dataLoader) ?? []
            return (buckets, [])
        }
    }

    private static func mergeVerifiedQuotas(
        modelQuotas: [AntigravityModelQuota],
        verifiedQuotas: [AntigravityModelQuota]) -> [AntigravityModelQuota]
    {
        var verifiedByModelID = Dictionary(
            uniqueKeysWithValues: verifiedQuotas.map { (Self.quotaKey($0), $0) })
        var merged = modelQuotas.compactMap { modelQuota -> AntigravityModelQuota? in
            guard let verifiedQuota = verifiedByModelID.removeValue(forKey: Self.quotaKey(modelQuota)) else {
                return nil
            }
            let resetTime = verifiedQuota.resetTime ?? modelQuota.resetTime
            return AntigravityModelQuota(
                label: modelQuota.label,
                modelId: modelQuota.modelId,
                remainingFraction: verifiedQuota.remainingFraction ?? modelQuota.remainingFraction,
                resetTime: resetTime,
                resetDescription: resetTime.map { UsageFormatter.resetDescription(from: $0) },
                remainingAmount: verifiedQuota.remainingAmount ?? modelQuota.remainingAmount)
        }
        let unmatchedVerifiedQuotas = verifiedByModelID.values
            .filter { $0.remainingFraction != nil }
            .sorted { lhs, rhs in
                lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
            }
        merged.append(contentsOf: unmatchedVerifiedQuotas)
        return merged
    }

    private static func quotaKey(_ quota: AntigravityModelQuota) -> String {
        quota.modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func shouldVerifyFullRemoteQuotas(_ quotas: [AntigravityModelQuota]) -> Bool {
        !quotas.isEmpty && quotas.allSatisfy { ($0.remainingFraction ?? 0) >= 0.999 }
    }

    private static func fetchQuotaBucketsIfPermitted(
        accessToken: String,
        projectId: String?,
        timeout: TimeInterval,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws
        -> [AntigravityModelQuota]?
    {
        do {
            let response: RetrieveUserQuotaResponse = try await Self.fetchQuotaResponse(
                endpoint: "\(Self.baseURL)/v1internal:retrieveUserQuota",
                accessToken: accessToken,
                projectId: projectId,
                timeout: timeout,
                dataLoader: dataLoader)
            return try Self.parseQuotaBuckets(response)
        } catch let quotaError as AntigravityRemoteFetchError {
            guard case .permissionDenied = quotaError else {
                throw quotaError
            }
            Self.log.info("Antigravity remote quota endpoint is not permitted for this account")
            return nil
        }
    }

    private static func resolveProjectID(
        accessToken: String,
        storedProjectID: String?,
        initialResponse: CodeAssistResponse,
        context: FetchContext) async throws
        -> String?
    {
        if let projectID = storedProjectID ?? initialResponse.projectID {
            return projectID
        }

        guard let tierID = Self.pickOnboardTier(from: initialResponse) else {
            return nil
        }

        let onboardBody: [String: Any] = [
            "tierId": tierID,
            "metadata": Self.clientMetadata,
        ]

        do {
            let onboardResponse: OnboardResponse = try await Self.sendRequest(
                endpoint: Self.onboardUserEndpoint,
                accessToken: accessToken,
                body: onboardBody,
                timeout: context.timeout,
                dataLoader: context.dataLoader)
            if let projectID = onboardResponse.projectID {
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

        let httpResponse = try await ProviderHTTPTransportHandler(dataLoader).response(for: request)

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AntigravityRemoteFetchError.notLoggedIn
        case 403:
            let message = String(data: httpResponse.data, encoding: .utf8)?.trimmedNonEmpty ?? "HTTP 403"
            throw AntigravityRemoteFetchError.permissionDenied(message)
        default:
            let message = String(data: httpResponse.data, encoding: .utf8)?.trimmedNonEmpty
                ?? "HTTP \(httpResponse.statusCode)"
            throw AntigravityRemoteFetchError.apiError("HTTP \(httpResponse.statusCode): \(message)")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: httpResponse.data)
        } catch {
            throw AntigravityRemoteFetchError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseModelCatalog(_ response: FetchAvailableModelsResponse) -> [AntigravityModelCatalogEntry] {
        let models = response.models ?? [:]
        return models.compactMap { modelID, model in
            let label = model.displayName?.trimmedNonEmpty
                ?? model.label?.trimmedNonEmpty
                ?? modelID
            return AntigravityModelCatalogEntry(
                modelId: modelID,
                label: label,
                creditMultiplier: model.creditMultiplier?.value,
                pricingType: model.pricingType?.rawValue,
                isPremium: model.isPremium,
                tagTitle: model.tagTitle).normalizedIfAttributed
        }
        .sorted { lhs, rhs in
            lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
        }
    }

    private static func parseModelQuotas(_ response: FetchAvailableModelsResponse) throws -> [AntigravityModelQuota] {
        let models = response.models ?? [:]
        return models.compactMap { modelID, model in
            guard let quotaInfo = model.quotaInfo else { return nil }
            let resetTime = ISO8601DateParser.parse(quotaInfo.resetTime)
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
        guard let buckets = response.buckets else {
            throw AntigravityRemoteFetchError.parseFailed("No quota buckets in response")
        }

        var modelQuotaMap: [String: (fraction: Double?, amount: Int?, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelID = bucket.modelId?.trimmedNonEmpty else { continue }
            let next = (
                fraction: bucket.remainingFraction,
                amount: bucket.remainingAmount?.value,
                resetTime: bucket.resetTime)
            if let existing = modelQuotaMap[modelID] {
                let existingFraction = existing.fraction ?? .greatestFiniteMagnitude
                let nextFraction = next.fraction ?? .greatestFiniteMagnitude
                if existingFraction < nextFraction {
                    continue
                }
                if existingFraction == nextFraction {
                    modelQuotaMap[modelID] = (
                        fraction: existing.fraction,
                        amount: existing.amount ?? next.amount,
                        resetTime: existing.resetTime ?? next.resetTime)
                    continue
                }
            }
            modelQuotaMap[modelID] = next
        }

        return modelQuotaMap.sorted { $0.key < $1.key }.map { modelID, info in
            let resetTime = ISO8601DateParser.parse(info.resetTime)
            return AntigravityModelQuota(
                label: modelID,
                modelId: modelID,
                remainingFraction: info.fraction,
                resetTime: resetTime,
                resetDescription: resetTime.map { UsageFormatter.resetDescription(from: $0) },
                remainingAmount: info.amount)
        }
    }

    private static func resolvePlan(response: CodeAssistResponse, claims: TokenClaims) -> String? {
        if let tier = response.paidTier,
           tier.name?.trimmedNonEmpty != nil || tier.id?.trimmedNonEmpty != nil
        {
            return AntigravityAccountMetadata.resolvedG1TierDisplayName(
                tierID: tier.id,
                g1Tier: response.g1Tier,
                rawName: tier.name) ?? "Paid"
        }
        if let g1TierPlan = AntigravityAccountMetadata.resolvedG1TierDisplayName(
            tierID: nil,
            g1Tier: response.g1Tier,
            rawName: nil)
        {
            return g1TierPlan
        }
        if let planType = response.planInfo?.planType?.trimmedNonEmpty {
            return planType
        }

        switch response.currentTier?.id?.trimmedNonEmpty {
        case "standard-tier":
            return AntigravityAccountMetadata.resolvedG1TierDisplayName(
                tierID: response.currentTier?.id,
                g1Tier: response.g1Tier,
                rawName: nil) ?? "Paid"
        case "free-tier":
            return claims.hostedDomain == nil ? "Free" : "Workspace"
        case "legacy-tier":
            return "Legacy"
        default:
            return AntigravityAccountMetadata.resolvedG1TierDisplayName(
                tierID: response.currentTier?.id,
                g1Tier: response.g1Tier,
                rawName: response.currentTier?.name)
        }
    }

    private static func resolveAccountMetadata(from response: CodeAssistResponse) -> AntigravityAccountMetadata? {
        let manageURI = response.manageSubscriptionUri?.trimmedNonEmpty
            ?? response.paidTier?.manageSubscriptionUri?.trimmedNonEmpty
            ?? response.currentTier?.manageSubscriptionUri?.trimmedNonEmpty
        let upgradeURI = response.upgradeSubscriptionUri?.trimmedNonEmpty
            ?? response.paidTier?.upgradeSubscriptionUri?.trimmedNonEmpty
            ?? response.currentTier?.upgradeSubscriptionUri?.trimmedNonEmpty
        let metadata = AntigravityAccountMetadata(
            g1Tier: response.g1Tier?.trimmedNonEmpty,
            gcpManaged: response.gcpManaged,
            manageSubscriptionURI: manageURI,
            upgradeSubscriptionURI: upgradeURI)
        return metadata.isEmpty ? nil : metadata
    }

    private static func resolveCredits(from response: CodeAssistResponse) -> AntigravityCreditsSnapshot? {
        let rawCredits = response.paidTier?.availableCredits ?? response.currentTier?.availableCredits ?? []
        let tierCredits = rawCredits.compactMap { credit -> AntigravityTierCredit? in
            let type = credit.creditType?.trimmedNonEmpty
            let amount = credit.creditAmount?.value
            let minimum = credit.minimumCreditAmountForUsage?.value
            guard type != nil || amount != nil || minimum != nil else { return nil }
            return AntigravityTierCredit(
                creditType: type,
                creditAmount: amount,
                minimumCreditAmountForUsage: minimum)
        }
        guard !tierCredits.isEmpty else { return nil }
        return AntigravityCreditsSnapshot(availableCredits: tierCredits)
    }

    private static func pickOnboardTier(from response: CodeAssistResponse) -> String? {
        response.allowedTiers?
            .first(where: { $0.isDefault == true && $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
            ?? response.allowedTiers?.first(where: { $0.id?.trimmedNonEmpty != nil })?.id?.trimmedNonEmpty
            ?? response.paidTier?.id?.trimmedNonEmpty
            ?? response.currentTier?.id?.trimmedNonEmpty
    }

    private static func resolveCredentialSource(
        homeDirectory: String,
        environment: [String: String]) throws -> (
        credentials: AntigravityOAuthCredentials?,
        store: AntigravityOAuthCredentialsStore?)
    {
        let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let primaryStore = AntigravityOAuthCredentialsStore(
            fileURL: AntigravityOAuthCredentialsStore.defaultURL(home: homeURL))
        if let tokenValue = environment[AntigravityOAuthCredentialsStore.environmentCredentialsKey] {
            guard let credentials = AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: tokenValue)
            else {
                throw AntigravityRemoteFetchError.parseFailed("Could not decode selected account credentials.")
            }
            return (credentials, nil)
        }
        return try (primaryStore.load(), primaryStore)
    }

    private struct RefreshResult {
        let accessToken: String
        let credentials: AntigravityOAuthCredentials
    }

    private static func refreshAccessToken(
        credentials: AntigravityOAuthCredentials,
        refreshToken: String,
        context: FetchContext) async throws
        -> RefreshResult
    {
        let oauthClient = try Self.refreshOAuthClient(
            from: credentials,
            oauthClientResolver: context.oauthClientResolver)

        var request = URLRequest(url: AntigravityOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = context.timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoding.body([
            "client_id": oauthClient.clientID,
            "client_secret": oauthClient.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let httpResponse = try await ProviderHTTPTransportHandler(context.dataLoader).response(for: request)
        guard httpResponse.statusCode == 200 else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }
        guard let json = try JSONSerialization.jsonObject(with: httpResponse.data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw AntigravityRemoteFetchError.parseFailed("Could not parse refresh response")
        }

        let updatedCredentials = Self.updatedCredentials(credentials, refreshResponse: json)
        try await context.persistCredentials(updatedCredentials)
        return RefreshResult(accessToken: accessToken, credentials: updatedCredentials)
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

    private static func updatedCredentials(
        _ credentials: AntigravityOAuthCredentials,
        refreshResponse: [String: Any]) -> AntigravityOAuthCredentials
    {
        var credentials = credentials
        if let accessToken = refreshResponse["access_token"] as? String {
            credentials.accessToken = accessToken
        }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            credentials.expiryDateMilliseconds = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        if let idToken = refreshResponse["id_token"] as? String {
            credentials.idToken = idToken
        }
        return credentials
    }

    private struct TokenClaims {
        let email: String?
        let hostedDomain: String?
    }

    private static func extractClaims(from credentials: AntigravityOAuthCredentials) -> TokenClaims {
        let claims = AntigravityOAuthCredentials.claims(fromIDToken: credentials.idToken)
        return TokenClaims(
            email: (claims?["email"] as? String)?.trimmedNonEmpty ?? credentials.email?.trimmedNonEmpty,
            hostedDomain: (claims?["hd"] as? String)?.trimmedNonEmpty)
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
    let ineligibleTiers: [IneligibleTier]?
    let cloudaicompanionProject: ProjectReference?
    let g1Tier: String?
    let gcpManaged: Bool?
    let manageSubscriptionUri: String?
    let upgradeSubscriptionUri: String?

    var projectID: String? {
        self.cloudaicompanionProject?.value?.trimmedNonEmpty
    }

    /// Consumer accounts are unonboarded when the token's OAuth client is not the consumer sign-in client.
    var rejectsClientForConsumerTier: Bool {
        self.currentTier == nil && self.projectID == nil && self.ineligibleTiers?.contains {
            $0.reasonCode == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"
        } == true
    }
}

private struct CodeAssistPlanInfo: Decodable {
    let planType: String?
}

private struct TierInfo: Decodable {
    let id: String?
    let name: String?
    let manageSubscriptionUri: String?
    let upgradeSubscriptionUri: String?
    let availableCredits: [CodeAssistCredit]?
}

private struct AllowedTier: Decodable {
    let id: String?
    let isDefault: Bool?
    let upgradeSubscriptionUri: String?
    let availableCredits: [CodeAssistCredit]?
}

private struct CodeAssistCredit: Decodable {
    let creditType: String?
    let creditAmount: FlexibleInt?
    let minimumCreditAmountForUsage: FlexibleInt?
}

private struct IneligibleTier: Decodable {
    let reasonCode: String?
}

private struct OnboardResponse: Decodable {
    let response: OnboardInnerResponse?

    var projectID: String? {
        self.response?.cloudaicompanionProject?.value?.trimmedNonEmpty
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
    let remainingAmount: FlexibleInt?
    let resetTime: String?

    private enum CodingKeys: String, CodingKey {
        case modelId
        case remainingFraction
        case remainingAmount
        case resetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        self.remainingFraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction)
        self.remainingAmount = try? container.decodeIfPresent(FlexibleInt.self, forKey: .remainingAmount)
        self.resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
    }
}

private struct AntigravityRemoteModel: Decodable {
    let displayName: String?
    let label: String?
    let quotaInfo: AntigravityRemoteQuotaInfo?
    let creditMultiplier: FlexibleDouble?
    let pricingType: CodeValue?
    let isPremium: Bool?
    let tagTitle: String?

    private enum CodingKeys: String, CodingKey {
        case displayName
        case displayNameSnake = "display_name"
        case label
        case quotaInfo
        case quotaInfoSnake = "quota_info"
        case creditMultiplier
        case creditMultiplierSnake = "credit_multiplier"
        case pricingType
        case pricingTypeSnake = "pricing_type"
        case isPremium
        case isPremiumSnake = "is_premium"
        case premium
        case tagTitle
        case tagTitleSnake = "tag_title"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .displayNameSnake)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.quotaInfo = try container.decodeIfPresent(AntigravityRemoteQuotaInfo.self, forKey: .quotaInfo)
            ?? container.decodeIfPresent(AntigravityRemoteQuotaInfo.self, forKey: .quotaInfoSnake)
        self.creditMultiplier = (try? container.decodeIfPresent(FlexibleDouble.self, forKey: .creditMultiplier))
            ?? (try? container.decodeIfPresent(FlexibleDouble.self, forKey: .creditMultiplierSnake))
        self.pricingType = (try? container.decodeIfPresent(CodeValue.self, forKey: .pricingType))
            ?? (try? container.decodeIfPresent(CodeValue.self, forKey: .pricingTypeSnake))
        self.isPremium = (try? container.decodeIfPresent(Bool.self, forKey: .isPremium))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .isPremiumSnake))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .premium))
        self.tagTitle = (try? container.decodeIfPresent(String.self, forKey: .tagTitle))
            ?? (try? container.decodeIfPresent(String.self, forKey: .tagTitleSnake))
    }
}

private struct AntigravityRemoteQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?

    private enum CodingKeys: String, CodingKey {
        case remainingFraction
        case remainingFractionSnake = "remaining_fraction"
        case resetTime
        case resetTimeSnake = "reset_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.remainingFraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction)
            ?? container.decodeIfPresent(Double.self, forKey: .remainingFractionSnake)
        self.resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
            ?? container.decodeIfPresent(String.self, forKey: .resetTimeSnake)
    }
}
