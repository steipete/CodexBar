import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxUsageFetcher: Sendable {
    static let log = CodexBarLog.logger(LogCategories.provider(.minimax, scope: "usage"))
    private static let billingHistoryLimit = 100
    struct WebFetchContext {
        let cookie: String
        let authorizationToken: String?
        let region: MiniMaxAPIRegion
        @ProcessEnvironment private(set) var environment: [String: String]
        let transport: any ProviderHTTPTransport
    }

    public static func fetchUsage(
        cookieHeader: String,
        authorizationToken: String? = nil,
        groupID: String? = nil,
        region: MiniMaxAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeBillingHistory: Bool = true,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> MiniMaxUsageSnapshot
    {
        guard let cookie = MiniMaxCookieHeader.normalized(from: cookieHeader) else {
            throw MiniMaxUsageError.invalidCredentials
        }
        if let rejectedKey = MiniMaxSettingsReader.rejectedEndpointOverrideKey(environment: environment) {
            throw ProviderEndpointOverrideError.minimax(rejectedKey)
        }

        let context = WebFetchContext(
            cookie: cookie,
            authorizationToken: authorizationToken,
            region: region,
            environment: environment,
            transport: transport)
        do {
            let htmlSnapshot = try await self.fetchCodingPlanHTML(context: context, now: now)
            if htmlSnapshot.services?.isEmpty != false {
                do {
                    Self.log.debug("MiniMax coding plan HTML lacks service quota data, trying remains API")
                    let remainsSnapshot = try await self.fetchCodingPlanRemains(
                        context: context,
                        groupID: groupID,
                        now: now)
                        .withPlanNameIfMissing(htmlSnapshot.planName)
                    let snapshot = try await self.attachingSubscriptionMetadataIfAvailable(
                        to: remainsSnapshot,
                        context: context,
                        groupID: groupID)
                    return try await self.attachingBillingIfAvailable(
                        to: snapshot,
                        context: context,
                        includeBillingHistory: includeBillingHistory,
                        now: now)
                } catch {
                    if self.shouldRethrowAfterHTMLFallback(error) {
                        throw error
                    }
                    Self.log.debug(
                        "MiniMax remains API enrichment failed after HTML fallback: \(error.localizedDescription)")
                }
            }
            let snapshot = try await self.attachingSubscriptionMetadataIfAvailable(
                to: htmlSnapshot,
                context: context,
                groupID: groupID)
            return try await self.attachingBillingIfAvailable(
                to: snapshot,
                context: context,
                includeBillingHistory: includeBillingHistory,
                now: now)
        } catch let error as MiniMaxUsageError {
            switch error {
            case .parseFailed:
                break
            case let .apiError(message) where ["HTTP 302", "HTTP 404", "HTTP 405"].contains(where: message.contains):
                break
            default:
                throw error
            }
            Self.log.debug("MiniMax coding plan page unavailable, trying remains API")
            let snapshot = try await self.attachingSubscriptionMetadataIfAvailable(
                to: self.fetchCodingPlanRemains(
                    context: context,
                    groupID: groupID,
                    now: now),
                context: context,
                groupID: groupID)
            return try await self.attachingBillingIfAvailable(
                to: snapshot,
                context: context,
                includeBillingHistory: includeBillingHistory,
                now: now)
        }
    }

    public static func fetchUsage(
        apiToken: String,
        region: MiniMaxAPIRegion = .global,
        now: Date = Date(),
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MiniMaxUsageSnapshot
    {
        let cleaned = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MiniMaxUsageError.invalidCredentials
        }

        // Historically, MiniMax API token fetching used a China endpoint by default in some configurations. If the
        // user has no persisted region and we default to `.global`, retry the China endpoint when the global host
        // rejects the token so upgrades don't regress existing setups.
        if region != .global {
            return try await self.fetchUsageOnce(apiToken: cleaned, region: region, now: now, transport: transport)
        }

        do {
            return try await self.fetchUsageOnce(
                apiToken: cleaned,
                region: .global,
                now: now,
                transport: transport)
        } catch let error as MiniMaxUsageError {
            guard case .invalidCredentials = error else { throw error }
            Self.log.debug("MiniMax API token rejected for global host, retrying China mainland host")
            do {
                return try await self.fetchUsageOnce(
                    apiToken: cleaned,
                    region: .chinaMainland,
                    now: now,
                    transport: transport)
            } catch {
                // Preserve the original invalid-credentials error so the fetch pipeline can fall back to web.
                Self.log.debug("MiniMax China mainland retry failed, preserving global invalidCredentials")
                throw MiniMaxUsageError.invalidCredentials
            }
        }
    }

    private static func fetchUsageOnce(
        apiToken: String,
        region: MiniMaxAPIRegion,
        now: Date,
        transport: any ProviderHTTPTransport) async throws -> MiniMaxUsageSnapshot
    {
        var lastError: Error?
        var tokenPlanCredentialFailure = false
        for remainsURL in [region.tokenPlanRemainsURL, region.apiRemainsURL] {
            do {
                return try await self.fetchAPIUsageOnce(
                    apiToken: apiToken,
                    remainsURL: remainsURL,
                    now: now,
                    transport: transport)
            } catch {
                guard error is MiniMaxUsageError || self.shouldTryNextEndpoint(after: error) else { throw error }
                lastError = error
                guard remainsURL == region.tokenPlanRemainsURL,
                      self.shouldTryNextEndpoint(after: error, retryRejectedCredentials: true)
                else {
                    if tokenPlanCredentialFailure {
                        throw MiniMaxUsageError.invalidCredentials
                    }
                    throw error
                }
                if case .invalidCredentials? = error as? MiniMaxUsageError {
                    tokenPlanCredentialFailure = true
                }
                Self.log.debug("MiniMax token-plan API failed, trying legacy coding-plan endpoint")
            }
        }
        if let lastError { throw lastError }
        throw MiniMaxUsageError.parseFailed("Missing MiniMax API remains URL.")
    }

    private static func fetchAPIUsageOnce(
        apiToken: String,
        remainsURL: URL,
        now: Date,
        transport: any ProviderHTTPTransport) async throws -> MiniMaxUsageSnapshot
    {
        var request = URLRequest(url: remainsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodexBar", forHTTPHeaderField: "MM-API-Source")

        let response = try await self.fetchResponse(for: request, transport: transport)

        do {
            return try self.parseRemainsResponse(response.data, now: now)
        } catch let error as MiniMaxUsageError {
            throw self.normalizedAPITokenError(error)
        }
    }

    private static func fetchResponse(
        for request: URLRequest,
        transport: any ProviderHTTPTransport) async throws -> ProviderHTTPResponse
    {
        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw self.normalizedTransportError(error)
        }

        guard response.statusCode == 200 else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(response.statusCode): \(body)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(response.statusCode)")
        }

        return response
    }

    private static func parseRemainsResponse(_ data: Data, now: Date) throws -> MiniMaxUsageSnapshot {
        let snapshot: MiniMaxUsageSnapshot
        do {
            snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
        } catch let error as MiniMaxUsageError {
            throw error
        } catch {
            throw MiniMaxUsageError.parseFailed(error.localizedDescription)
        }
        if let services = snapshot.services, !services.isEmpty {
            Self.log.debug("MiniMax multi-service response detected: \(services.count) services")
        }
        return snapshot
    }

    private static func normalizedAPITokenError(_ error: MiniMaxUsageError) -> MiniMaxUsageError {
        guard case let .apiError(message) = error else { return error }
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedMessage == "invalid api key" ? .invalidCredentials : error
    }

    private static func shouldTryNextEndpoint(after error: Error, retryRejectedCredentials: Bool = false) -> Bool {
        guard let error = error as? MiniMaxUsageError else {
            let error = error as NSError
            return error.domain == NSURLErrorDomain && error.code != NSURLErrorCancelled
        }
        return switch error {
        case .invalidCredentials:
            retryRejectedCredentials
        case let .apiError(message):
            message.contains("HTTP 302") || message.contains("HTTP 404") || message.contains("HTTP 405")
        case .networkError, .parseFailed:
            true
        }
    }

    private static func makeWebRequest(
        url: URL,
        context: WebFetchContext,
        accept: String) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(context.cookie, forHTTPHeaderField: "Cookie")
        if let authorizationToken = context.authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(accept, forHTTPHeaderField: "accept")
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        let origin = self.originURL(from: url)
        request.setValue(origin.absoluteString, forHTTPHeaderField: "origin")
        request.setValue(
            self.resolveCodingPlanRefererURL(region: context.region, environment: context.environment).absoluteString,
            forHTTPHeaderField: "referer")

        return request
    }

    private static func fetchCodingPlanHTML(
        context: WebFetchContext,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        let url = self.resolveCodingPlanURL(region: context.region, environment: context.environment)
        let request = self.makeWebRequest(
            url: url,
            context: context,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        let response = try await self.fetchResponse(for: request, transport: context.transport)

        if let contentType = response.response.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("application/json")
        {
            return try self.parseRemainsResponse(response.data, now: now)
        }

        let html = String(data: response.data, encoding: .utf8) ?? ""
        if html.contains("__NEXT_DATA__") {
            Self.log.debug("MiniMax coding plan HTML contains __NEXT_DATA__")
        }
        if self.looksSignedOut(html: html) {
            throw MiniMaxUsageError.invalidCredentials
        }
        return try MiniMaxUsageParser.parse(html: html, now: now)
    }

    private static func fetchCodingPlanRemains(
        context: WebFetchContext,
        groupID: String?,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        var lastError: Error?
        for baseRemainsURL in self.resolveRemainsURLs(region: context.region, environment: context.environment) {
            do {
                return try await self.fetchCodingPlanRemainsOnce(
                    baseRemainsURL: baseRemainsURL,
                    context: context,
                    groupID: groupID,
                    now: now)
            } catch {
                lastError = error
                guard self.shouldTryNextEndpoint(after: error) else { throw error }
                Self.log.debug("MiniMax remains API failed for \(baseRemainsURL.host ?? "unknown host"), trying next")
            }
        }
        if let lastError { throw lastError }
        throw MiniMaxUsageError.parseFailed("Missing MiniMax remains URL.")
    }

    private static func fetchCodingPlanRemainsOnce(
        baseRemainsURL: URL,
        context: WebFetchContext,
        groupID: String?,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        let isCurrentChinaEndpoint = baseRemainsURL.path == "/backend/account/token_plan/remains_percent"
        let remainsURL = isCurrentChinaEndpoint ? baseRemainsURL : self.appendGroupID(groupID, to: baseRemainsURL)
        var request = self.makeWebRequest(
            url: remainsURL,
            context: context,
            accept: "application/json, text/plain, */*")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        if isCurrentChinaEndpoint {
            let pageURL = self.resolveCodingPlanURL(region: context.region, environment: context.environment)
            request.setValue(self.originURL(from: pageURL).absoluteString, forHTTPHeaderField: "origin")
            if let groupID, !groupID.isEmpty {
                request.setValue(groupID, forHTTPHeaderField: "X-Group-Id")
            }
        }
        let response = try await self.fetchResponse(for: request, transport: context.transport)

        if let contentType = response.response.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("application/json")
        {
            return try self.parseRemainsResponse(response.data, now: now)
        }

        let html = String(data: response.data, encoding: .utf8) ?? ""
        if self.looksSignedOut(html: html) {
            throw MiniMaxUsageError.invalidCredentials
        }
        return try MiniMaxUsageParser.parse(html: html, now: now)
    }

    private static func normalizedTransportError(_ error: Error) -> Error {
        let original = error as NSError
        guard original.domain == NSURLErrorDomain, original.code != NSURLErrorCancelled else { return error }
        // Keep transport identity for cache/retry policy and MiniMax text for diagnostic classification.
        var userInfo = original.userInfo
        let description = original.code == NSURLErrorBadServerResponse ? "Invalid response" : original
            .localizedDescription
        userInfo[NSLocalizedDescriptionKey] = MiniMaxUsageError.networkError(description).localizedDescription
        return NSError(domain: original.domain, code: original.code, userInfo: userInfo)
    }

    private static func shouldRethrowAfterHTMLFallback(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let minimaxError = error as? MiniMaxUsageError {
            if case .invalidCredentials = minimaxError { return true }
        }
        if error is ProviderEndpointOverrideError { return true }
        return false
    }

    private static func attachingBillingIfAvailable(
        to snapshot: MiniMaxUsageSnapshot,
        context: WebFetchContext,
        includeBillingHistory: Bool,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        guard includeBillingHistory else { return snapshot }
        do {
            let billing = try await self.fetchBillingSummary(context: context, now: now)
            return snapshot.withBillingSummary(billing)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as MiniMaxUsageError {
            if case .invalidCredentials = error, context.authorizationToken != nil {
                throw error
            }
            Self.log.debug("MiniMax billing history unavailable: \(error.localizedDescription)")
            return snapshot
        } catch {
            Self.log.debug("MiniMax billing history unavailable: \(error.localizedDescription)")
            return snapshot
        }
    }

    private static func fetchBillingSummary(context: WebFetchContext, now: Date) async throws -> MiniMaxBillingSummary {
        var records: [MiniMaxBillingRecord] = []
        var totalCount: Int?

        var page = 1
        while true {
            let url = self.resolveBillingHistoryURL(
                region: context.region,
                environment: context.environment,
                page: page,
                limit: Self.billingHistoryLimit)
            let response = try await self.billingHistoryResponse(url: url, context: context)
            guard response.statusCode == 200 else {
                let body = String(data: response.data, encoding: .utf8) ?? ""
                Self.log.debug("MiniMax billing history returned \(response.statusCode): \(body)")
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw MiniMaxUsageError.invalidCredentials
                }
                throw MiniMaxUsageError.apiError("HTTP \(response.statusCode)")
            }

            let payload = try MiniMaxBillingHistoryParser.decodePayload(data: response.data)
            if let status = payload.baseResp?.statusCode, status != 0 {
                let message = payload.baseResp?.statusMessage ?? "status_code \(status)"
                throw MiniMaxUsageError.apiError(message)
            }
            totalCount = payload.totalCount ?? totalCount
            guard !payload.chargeRecords.isEmpty else { break }
            records.append(contentsOf: payload.chargeRecords)
            if MiniMaxBillingHistoryParser.containsRecordBefore30DayWindow(payload.chargeRecords, now: now) { break }
            if let totalCount, records.count >= totalCount { break }
            page += 1
        }

        return MiniMaxBillingHistoryParser.aggregate(records: records, now: now)
    }

    private static func billingHistoryResponse(
        url: URL,
        context: WebFetchContext) async throws -> ProviderHTTPResponse
    {
        var request = self.makeWebRequest(
            url: url,
            context: context,
            accept: "application/json, text/plain, */*")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        request.setValue(
            self.originURL(from: url).appendingPathComponent("account").absoluteString,
            forHTTPHeaderField: "referer")

        do {
            return try await context.transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw MiniMaxUsageError.networkError("Invalid response")
        } catch {
            throw error
        }
    }

    private static func appendGroupID(_ groupID: String?, to url: URL) -> URL {
        guard let groupID, !groupID.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "GroupId", value: groupID))
        components.queryItems = queryItems
        return components.url ?? url
    }

    static func originURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    static func resolveCodingPlanURL(
        region: MiniMaxAPIRegion,
        environment: [String: String]) -> URL
    {
        if let override = MiniMaxSettingsReader.codingPlanURL(environment: environment) {
            return override
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment),
           let hostURL = self.url(
               from: host,
               path: MiniMaxAPIRegion.codingPlanPath,
               query: MiniMaxAPIRegion.codingPlanQuery)
        {
            return hostURL
        }
        return region.codingPlanURL
    }

    static func resolveCodingPlanRefererURL(
        region: MiniMaxAPIRegion,
        environment: [String: String]) -> URL
    {
        let url = self.resolveCodingPlanURL(region: region, environment: environment)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        return components.url ?? url
    }

    static func resolveRemainsURLs(
        region: MiniMaxAPIRegion,
        environment: [String: String]) -> [URL]
    {
        if let override = MiniMaxSettingsReader.remainsURL(environment: environment) {
            return [override]
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment),
           let hostURL = self.url(from: host, path: MiniMaxAPIRegion.remainsPath)
        {
            return [hostURL]
        }

        let currentChinaURL = URL(string: "https://www.minimax.cn/backend/account/token_plan/remains_percent")!
        let current = region == .chinaMainland ? [currentChinaURL] : []
        return current + [
            region.remainsURL,
            URL(string: region.webBaseURLString)!.appendingPathComponent(MiniMaxAPIRegion.remainsPath),
        ]
    }

    static func resolveBillingHistoryURL(
        region: MiniMaxAPIRegion,
        environment: [String: String],
        page: Int,
        limit: Int = Self.billingHistoryLimit) -> URL
    {
        if let override = MiniMaxSettingsReader.billingHistoryURL(environment: environment) {
            return self.billingHistoryURL(from: override, page: page, limit: limit)
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment),
           let hostURL = self.url(from: host, path: MiniMaxAPIRegion.billingHistoryPath)
        {
            return self.billingHistoryURL(from: hostURL, page: page, limit: limit)
        }
        return region.billingHistoryURL(page: page, limit: limit)
    }

    private static func billingHistoryURL(from url: URL, page: Int, limit: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems?.filter {
            $0.name != "page" && $0.name != "limit" && $0.name != "aggregate"
        } ?? []
        items.append(URLQueryItem(name: "page", value: "\(page)"))
        items.append(URLQueryItem(name: "limit", value: "\(limit)"))
        items.append(URLQueryItem(name: "aggregate", value: "false"))
        components.queryItems = items
        return components.url ?? url
    }

    static func url(from raw: String, path: String? = nil, query: String? = nil) -> URL? {
        guard let cleaned = SettingsValue.cleaned(raw),
              let base = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: cleaned) else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if let path { components.path = "/" + path }
        if let query { components.query = query }
        return components.url
    }

    static func looksSignedOut(html: String) -> Bool {
        let lower = self.visibleText(from: html).lowercased()
        return lower.contains("sign in") || lower.contains("log in") || lower.contains("登录") || lower.contains("登入")
    }

    private static func visibleText(from html: String) -> String {
        let patterns = [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<!--.*?-->"#,
            #"<[^>]+>"#,
            #"\s+"#,
        ]

        return patterns.enumerated().reduce(html) { result, item in
            let replacement = item.offset == patterns.count - 1 ? " " : ""
            return result.replacingOccurrences(
                of: item.element,
                with: replacement,
                options: .regularExpression)
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MiniMaxCodingPlanPayload: Decodable {
    let baseResp: MiniMaxBaseResponse?
    let data: MiniMaxCodingPlanData

    private enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseResp = try container.decodeIfPresent(MiniMaxBaseResponse.self, forKey: .baseResp)
        if container.contains(.data) {
            let dataDecoder = try container.superDecoder(forKey: .data)
            self.data = try MiniMaxCodingPlanData(from: dataDecoder)
        } else {
            self.data = try MiniMaxCodingPlanData(from: decoder)
        }
    }
}

struct MiniMaxCodingPlanData: Decodable {
    let baseResp: MiniMaxBaseResponse?
    let currentSubscribeTitle: String?
    let planName: String?
    let comboTitle: String?
    let currentPlanTitle: String?
    let currentComboCard: MiniMaxComboCard?
    let pointsBalance: Double?
    let modelRemains: [MiniMaxModelRemains]

    private enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
        case pointsBalance = "points_balance"
        case pointBalance = "point_balance"
        case creditsBalance = "credits_balance"
        case creditBalance = "credit_balance"
        case balance
        case modelRemains = "model_remains"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseResp = try container.decodeIfPresent(MiniMaxBaseResponse.self, forKey: .baseResp)
        self.currentSubscribeTitle = try container.decodeIfPresent(String.self, forKey: .currentSubscribeTitle)
        self.planName = try container.decodeIfPresent(String.self, forKey: .planName)
        self.comboTitle = try container.decodeIfPresent(String.self, forKey: .comboTitle)
        self.currentPlanTitle = try container.decodeIfPresent(String.self, forKey: .currentPlanTitle)
        self.currentComboCard = try container.decodeIfPresent(MiniMaxComboCard.self, forKey: .currentComboCard)
        self.pointsBalance = MiniMaxDecoding.decodeDouble(container, forKeys: [
            .pointsBalance,
            .pointBalance,
            .creditsBalance,
            .creditBalance,
            .balance,
        ])
        self.modelRemains = try (container.decodeIfPresent([MiniMaxModelRemains].self, forKey: .modelRemains)) ?? []
    }
}

struct MiniMaxComboCard: Decodable {
    let title: String?
}

struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int?
    let statusMessage: String?

    private enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_msg"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.statusCode = MiniMaxDecoding.decodeInt(container, forKey: .statusCode)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
    }
}

// MARK: - Multi-Service API Response Structures

struct MiniMaxMultiServicePayload: Decodable {
    let data: MiniMaxMultiServiceData
}

struct MiniMaxMultiServiceData: Decodable {
    let services: [MiniMaxServiceItem]
}

struct MiniMaxServiceItem: Decodable {
    let serviceType: String?
    let windowType: String?
    let timeRange: String?
    let usage: Int?
    let limit: Int?
    let percent: Double?

    private enum CodingKeys: String, CodingKey {
        case serviceType = "service_type"
        case windowType = "window_type"
        case timeRange = "time_range"
        case usage
        case limit
        case percent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serviceType = try container.decodeIfPresent(String.self, forKey: .serviceType)
        self.windowType = try container.decodeIfPresent(String.self, forKey: .windowType)
        self.timeRange = try container.decodeIfPresent(String.self, forKey: .timeRange)
        self.usage = MiniMaxDecoding.decodeInt(container, forKey: .usage)
        self.limit = MiniMaxDecoding.decodeInt(container, forKey: .limit)
        // Handle both Double and String for percent (flexible parsing)
        if let percentDouble = try? container.decodeIfPresent(Double.self, forKey: .percent) {
            self.percent = percentDouble
        } else if let percentString = try? container.decodeIfPresent(String.self, forKey: .percent),
                  let percentValue = Double(percentString)
        {
            self.percent = percentValue
        } else {
            self.percent = nil
        }
    }
}

enum MiniMaxUsageParser {
    static func decodePayload(data: Data) throws -> MiniMaxCodingPlanPayload {
        try JSONDecoder().decode(MiniMaxCodingPlanPayload.self, from: data)
    }

    static func decodePayload(json: [String: Any]) throws -> MiniMaxCodingPlanPayload {
        let normalized = self.normalizeCodingPlanPayload(json)
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [])
        return try self.decodePayload(data: data)
    }

    static func parseCodingPlanRemains(data: Data, now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        do {
            if let multiServiceSnapshot = try self.parseMultiService(data: data, now: now) {
                return multiServiceSnapshot
            }
        } catch {
            // Log multi-service parsing failure but continue to single-service parsing
            MiniMaxUsageFetcher.log.debug("MiniMax multi-service parsing failed: \(error.localizedDescription)")
        }

        let payload = try self.decodePayload(data: data)
        return try self.parseCodingPlanRemains(payload: payload, now: now)
    }

    static func parse(html: String, now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        if let snapshot = self.parseNextData(html: html, now: now) {
            return snapshot
        }
        let text = self.stripHTML(html)

        let planName = self.parsePlanName(html: html, text: text)
        let available = self.parseAvailableUsage(text: text)
        let usedPercent = self.parseUsedPercent(text: text)
        let resetsAt = self.parseResetsAt(text: text, now: now)

        if planName == nil, available == nil, usedPercent == nil {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        return MiniMaxUsageSnapshot(
            planName: planName,
            availablePrompts: available?.prompts,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: available?.windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            updatedAt: now)
    }

    static func parseCodingPlanRemains(
        payload: MiniMaxCodingPlanPayload,
        now: Date = Date()) throws -> MiniMaxUsageSnapshot
    {
        let baseResponse = payload.data.baseResp ?? payload.baseResp
        if let status = baseResponse?.statusCode, status != 0 {
            let message = baseResponse?.statusMessage ?? "status_code \(status)"
            let lower = message.lowercased()
            if status == 1004 || lower.contains("cookie") || lower.contains("log in") || lower.contains("login") {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError(message)
        }

        guard !payload.data.modelRemains.isEmpty else {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        // Convert model_remains to services array for multi-service UI display
        var services: [MiniMaxServiceUsage] = []
        for item in payload.data.modelRemains {
            guard let modelName = item.modelName else { continue }
            let serviceTypeIdentifier = self.mapModelNameToServiceType(modelName: modelName)

            if let intervalService = self.makeServiceUsage(
                ServiceUsageInput(
                    serviceType: serviceTypeIdentifier,
                    isWebPercentSchema: item.hasIntervalUsedPercent,
                    windowTypeOverride: item.hasIntervalUsedPercent && item.startTime == nil ? "5 hours" : nil,
                    total: item.currentIntervalTotalCount,
                    remaining: item.currentIntervalUsageCount,
                    remainingPercent: item.currentIntervalRemainingPercent,
                    status: item.currentIntervalStatus,
                    start: item.startTime,
                    end: item.endTime,
                    remainsTime: item.remainsTime,
                    boostPermille: item.intervalBoostPermille),
                now: now)
            {
                services.append(intervalService)
            }

            // current_weekly_usage_count is also REMAINING quota; render only when weekly quota is real.
            if self.isTextGenerationModelName(modelName),
               let weeklyService = self.makeServiceUsage(
                   ServiceUsageInput(
                       serviceType: serviceTypeIdentifier,
                       isWebPercentSchema: item.hasWeeklyUsedPercent,
                       windowTypeOverride: "Weekly",
                       total: item.currentWeeklyTotalCount,
                       remaining: item.currentWeeklyUsageCount,
                       remainingPercent: item.currentWeeklyRemainingPercent,
                       status: item.currentWeeklyStatus,
                       start: item.weeklyStartTime,
                       end: item.weeklyEndTime,
                       remainsTime: item.weeklyRemainsTime,
                       boostPermille: item.weeklyBoostPermille),
                   now: now)
            {
                services.append(weeklyService)
            }
        }

        // Use first service for backward compatibility fields
        let first = payload.data.modelRemains.first
        let hasPercentQuota = first?.currentIntervalRemainingPercent != nil
        let total = hasPercentQuota && first?.currentIntervalTotalCount == 0 ? nil : first?.currentIntervalTotalCount
        let remaining = hasPercentQuota && first?.currentIntervalUsageCount == 0
            ? nil
            : first?.currentIntervalUsageCount
        let usedPercent = self.usedPercent(
            total: total,
            remaining: remaining,
            remainingPercent: first?.currentIntervalRemainingPercent)

        let windowMinutes = self.windowMinutes(
            start: self.dateFromEpoch(first?.startTime),
            end: self.dateFromEpoch(first?.endTime))

        let resetsAt = self.resetsAt(
            end: self.dateFromEpoch(first?.endTime),
            remains: first?.remainsTime,
            now: now)

        let planName = self.parsePlanName(data: payload.data)

        let currentPrompts: Int? = if let total, let remaining {
            max(0, total - remaining)
        } else {
            nil
        }

        return MiniMaxUsageSnapshot(
            planName: planName,
            availablePrompts: total,
            currentPrompts: currentPrompts,
            remainingPrompts: remaining,
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            updatedAt: now,
            services: services.isEmpty ? nil : services,
            pointsBalance: payload.data.pointsBalance)
    }

    private static func usedPercent(total: Int?, remaining: Int?, remainingPercent: Double? = nil) -> Double? {
        if let remainingPercent {
            return self.usedPercent(remainingPercent: remainingPercent)
        }
        guard let total, total > 0, let remaining else { return nil }
        let used = max(0, total - remaining)
        let percent = Double(used) / Double(total) * 100
        return min(100, max(0, percent))
    }

    private static func usedPercent(remainingPercent: Double) -> Double {
        min(100, max(0, 100 - remainingPercent))
    }

    private static func dateFromEpoch(_ value: Int?) -> Date? {
        guard let raw = value else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw) / 1000)
        }
        if raw > 1_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw))
        }
        return nil
    }

    private static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }

    private static func resetsAt(end: Date?, remains: Int?, now: Date) -> Date? {
        if let end, end > now {
            return end
        }
        guard let remains, remains > 0 else { return nil }
        let seconds: TimeInterval = remains > 1_000_000 ? TimeInterval(remains) / 1000 : TimeInterval(remains)
        return now.addingTimeInterval(seconds)
    }

    private static func parsePlanName(data: MiniMaxCodingPlanData) -> String? {
        [
            data.currentSubscribeTitle,
            data.planName,
            data.comboTitle,
            data.currentPlanTitle,
            data.currentComboCard?.title,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? self.inferredTokenPlanName(data: data)
    }

    private static func inferredTokenPlanName(data: MiniMaxCodingPlanData) -> String? {
        let hasTextGeneration = data.modelRemains.contains { $0.modelName.map(self.isTextGenerationModelName) ?? false }
        let hasUnavailableVideo = data.modelRemains.contains { item in
            item.modelName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "video" &&
                self.isUnavailableQuotaPlaceholder(ServiceUsageInput(
                    serviceType: "Text to Video",
                    isWebPercentSchema: false,
                    windowTypeOverride: nil,
                    total: item.currentIntervalTotalCount,
                    remaining: item.currentIntervalUsageCount,
                    remainingPercent: item.currentIntervalRemainingPercent,
                    status: item.currentIntervalStatus,
                    start: nil,
                    end: nil,
                    remainsTime: nil,
                    boostPermille: nil))
        }
        return hasTextGeneration && hasUnavailableVideo ? "Plus" : nil
    }

    private static func parsePlanName(html: String, text: String) -> String? {
        [
            self.extractFirst(pattern: #"(?i)"planName"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)"plan"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)"packageName"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)Coding\s*Plan\s*([A-Za-z0-9][A-Za-z0-9\s._-]{0,32})"#, text: text),
        ]
            .compactMap(\.self)
            .map {
                UsageFormatter.cleanPlanName($0)
                    .replacingOccurrences(
                        of: #"(?i)\s+available\s+usage.*$"#,
                        with: "",
                        options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first { !$0.isEmpty }
    }

    private static func parseNextData(html: String, now: Date) -> MiniMaxUsageSnapshot? {
        guard let data = self.nextDataJSONData(fromHTML: html),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = self.findCodingPlanPayload(in: object),
              let decoded = try? self.decodePayload(json: payload)
        else {
            return nil
        }
        return try? self.parseCodingPlanRemains(payload: decoded, now: now)
    }

    private static func findCodingPlanPayload(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if dict["model_remains"] != nil || dict["modelRemains"] != nil {
                return dict
            }
            for value in dict.values {
                if let match = self.findCodingPlanPayload(in: value) {
                    return match
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let match = self.findCodingPlanPayload(in: value) {
                    return match
                }
            }
        }
        return nil
    }

    private static func normalizeCodingPlanPayload(_ payload: [String: Any]) -> [String: Any] {
        var normalized = payload

        let aliases = [
            ("model_remains", "modelRemains"),
            ("current_subscribe_title", "currentSubscribeTitle"),
            ("plan_name", "planName"),
            ("combo_title", "comboTitle"),
            ("current_plan_title", "currentPlanTitle"),
            ("current_combo_card", "currentComboCard"),
            ("base_resp", "baseResp"),
            ("points_balance", "pointsBalance"),
            ("credits_balance", "creditsBalance"),
        ]
        for (key, alias) in aliases where normalized[key] == nil {
            normalized[key] = normalized[alias]
        }

        if let data = normalized["data"] as? [String: Any] {
            normalized["data"] = self.normalizeCodingPlanPayload(data)
        }

        return normalized
    }

    private static let nextDataNeedle = Data("id=\"__NEXT_DATA__\"".utf8)
    private static let scriptCloseNeedle = Data("</script>".utf8)

    private static func nextDataJSONData(fromHTML html: String) -> Data? {
        let data = Data(html.utf8)
        guard let idRange = data.range(of: self.nextDataNeedle),
              let openTagEnd = data[idRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        let contentStart = data.index(after: openTagEnd)
        guard let closeRange = data.range(
            of: self.scriptCloseNeedle,
            options: [],
            in: contentStart..<data.endIndex)
        else { return nil }
        return Data(data[contentStart..<closeRange.lowerBound])
    }

    private static func parseAvailableUsage(text: String) -> (prompts: Int, windowMinutes: Int)? {
        let pattern =
            #"(?i)available\s+usage[:\s]*([0-9][0-9,]*)\s*prompts?\s*/\s*"# +
            #"([0-9]+(?:\.[0-9]+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|days?|d)"#
        guard let match = self.extractMatch(pattern: pattern, text: text), match.count >= 3 else { return nil }
        let promptsRaw = match[0]
        let durationRaw = match[1]
        let unitRaw = match[2]

        let prompts = Int(promptsRaw.replacingOccurrences(of: ",", with: "")) ?? 0
        guard prompts > 0,
              let duration = Double(durationRaw),
              let windowMinutes = self.minutes(from: duration, unit: unitRaw),
              windowMinutes > 0 else { return nil }
        return (prompts, windowMinutes)
    }

    private static func parseUsedPercent(text: String) -> Double? {
        let patterns = [
            #"(?i)([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used"#,
            #"(?i)used\s*([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#,
        ]
        for pattern in patterns {
            if let raw = self.extractFirst(pattern: pattern, text: text),
               let value = Double(raw),
               value >= 0,
               value <= 100
            {
                return value
            }
        }
        return nil
    }

    private static func parseResetsAt(text: String, now: Date) -> Date? {
        if let match = self.extractMatch(
            pattern: #"(?i)resets?\s+in\s+([0-9]+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)"#,
            text: text),
            match.count >= 2,
            let value = Double(match[0])
        {
            let unit = match[1]
            let seconds = self.seconds(from: value, unit: unit)
            return now.addingTimeInterval(seconds)
        }

        if let match = self.extractMatch(
            pattern: #"(?i)resets?\s+at\s+([0-9]{1,2}:[0-9]{2})(?:\s*\(([^)]+)\))?"#,
            text: text),
            match.count >= 1
        {
            let timeText = match[0]
            let tzText = match.count > 1 ? match[1] : nil
            return self.dateForTime(timeText, timeZoneHint: tzText, now: now)
        }

        return nil
    }

    private static func dateForTime(_ time: String, timeZoneHint: String?, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if let tzHint = timeZoneHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tzHint.isEmpty
        {
            formatter.timeZone = self.timeZone(from: tzHint)
        }
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let timeOnly = formatter.date(from: time) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone ?? .current

        let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)
        var targetComponents = calendar.dateComponents([.hour, .minute], from: timeOnly)
        targetComponents.year = nowComponents.year
        targetComponents.month = nowComponents.month
        targetComponents.day = nowComponents.day
        guard var candidate = calendar.date(from: targetComponents) else { return nil }

        if candidate < now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private static func minutes(from value: Double, unit: String) -> Int? {
        let lower = unit.lowercased()
        if lower.hasPrefix("d") { return Int(exactly: (value * 24 * 60).rounded()) }
        if lower.hasPrefix("h") { return Int(exactly: (value * 60).rounded()) }
        if lower.hasPrefix("m") { return Int(exactly: value.rounded()) }
        if lower.hasPrefix("s"), let minutes = Int(exactly: (value / 60).rounded()) { return max(1, minutes) }
        return nil
    }

    private static func timeZone(from hint: String) -> TimeZone? {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let timeZone = TimeZone(identifier: trimmed) {
            return timeZone
        }

        let pattern = #"(?i)^(?:UTC|GMT)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let signRange = Range(match.range(at: 1), in: trimmed),
              let hourRange = Range(match.range(at: 2), in: trimmed)
        else {
            return nil
        }

        let sign = trimmed[signRange] == "-" ? -1 : 1
        let hours = Int(trimmed[hourRange]) ?? 0
        let minutes = if match.range(at: 3).location != NSNotFound,
                         let minuteRange = Range(match.range(at: 3), in: trimmed)
        {
            Int(trimmed[minuteRange]) ?? 0
        } else {
            0
        }
        return TimeZone(secondsFromGMT: sign * ((hours * 3600) + (minutes * 60)))
    }

    private static func seconds(from value: Double, unit: String) -> TimeInterval {
        let lower = unit.lowercased()
        if lower.hasPrefix("d") { return value * 24 * 60 * 60 }
        if lower.hasPrefix("h") { return value * 60 * 60 }
        if lower.hasPrefix("m") { return value * 60 }
        return value
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractMatch(pattern: String, text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { idx in
            guard let captureRange = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Multi-Service Parsing

    private static func parseMultiService(data: Data, now: Date) throws -> MiniMaxUsageSnapshot? {
        let payload = try JSONDecoder().decode(MiniMaxMultiServicePayload.self, from: data)

        guard !payload.data.services.isEmpty else {
            return nil
        }

        var services: [MiniMaxServiceUsage] = []
        for item in payload.data.services {
            guard let serviceType = item.serviceType,
                  let windowType = item.windowType,
                  let timeRange = item.timeRange,
                  let usage = item.usage,
                  let limit = item.limit,
                  limit > 0
            else {
                continue
            }

            let percent = item.percent ?? (Double(usage) / Double(limit) * 100.0)

            let resetsAt = self.parseResetsAtFromTimeRange(timeRange: timeRange, windowType: windowType, now: now)
            let resetDescription = self.resetDescription(
                for: windowType,
                timeRange: timeRange,
                now: now,
                resetsAt: resetsAt)

            let serviceTypeIdentifier: String = if serviceType.lowercased().contains("text"),
                                                   serviceType.lowercased().contains("generation")
            {
                "text-generation"
            } else if serviceType.lowercased().contains("text"), serviceType.lowercased().contains("speech") {
                "text-to-speech"
            } else if serviceType.lowercased().contains("image") {
                "image"
            } else {
                serviceType.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "_", with: "-")
            }

            let serviceUsage = MiniMaxServiceUsage(
                serviceType: serviceTypeIdentifier,
                windowType: windowType,
                timeRange: timeRange,
                usage: usage,
                limit: limit,
                percent: min(100.0, max(0.0, percent)),
                resetsAt: resetsAt,
                resetDescription: resetDescription)
            services.append(serviceUsage)
        }

        if services.isEmpty {
            return nil
        }

        let planName = self.extractPlanNameFromServices(services: payload.data.services)

        return MiniMaxUsageSnapshot(
            planName: planName,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: services)
    }

    private static func parseResetsAtFromTimeRange(timeRange: String, windowType: String, now: Date) -> Date? {
        let lowerWindow = windowType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lowerWindow == "today" {
            let components = timeRange.split(separator: "-", maxSplits: 1)
            guard components.count == 2 else { return nil }

            let endTimeStr = String(components[1].trimmingCharacters(in: .whitespacesAndNewlines))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

            return formatter.date(from: endTimeStr)
        }

        if lowerWindow.contains("hour") || lowerWindow.contains("h") {
            let timeComponents = timeRange.split(separator: "-")
            guard timeComponents.count >= 2 else { return nil }

            let endTimePart = String(timeComponents[1])
            let endTimeClean = endTimePart.replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return self.dateForTime(endTimeClean, timeZoneHint: "UTC+8", now: now)
        }

        return nil
    }

    private static func resetDescription(
        for windowType: String,
        timeRange: String,
        now: Date,
        resetsAt: Date?) -> String
    {
        if let resetsAt, resetsAt > now {
            let interval = resetsAt.timeIntervalSince(now)
            if interval < 60 {
                return "Resets in \(Int(interval)) seconds"
            } else if interval < 3600 {
                let minutes = Int(interval / 60)
                return "Resets in \(minutes) minute\(minutes == 1 ? "" : "s")"
            } else if interval < 86400 {
                let hours = Int(interval / 3600)
                return "Resets in \(hours) hour\(hours == 1 ? "" : "s")"
            } else {
                let days = Int(interval / 86400)
                return "Resets in \(days) day\(days == 1 ? "" : "s")"
            }
        }

        return "\(windowType): \(timeRange)"
    }

    private static func extractPlanNameFromServices(services: [MiniMaxServiceItem]) -> String? {
        for service in services {
            if let serviceType = service.serviceType,
               serviceType.lowercased().contains("pro") || serviceType.lowercased().contains("max")
            {
                return serviceType
            }
        }

        return nil
    }

    private static func parseWindowInfo(
        startTime: Date?,
        endTime: Date?) -> (windowType: String, timeRange: String)
    {
        guard let startTime, let endTime else {
            return (windowType: "Unknown", timeRange: "N/A")
        }

        let durationSeconds = endTime.timeIntervalSince(startTime)
        let durationHours = durationSeconds / 3600

        let windowType = if durationHours >= 23, durationHours <= 25 {
            "Today"
        } else if durationHours >= 4, durationHours <= 6 {
            "5 hours"
        } else if durationHours >= 1, durationHours < 23 {
            "\(Int(durationHours)) hours"
        } else {
            "Custom"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let startStr = formatter.string(from: startTime)
        let endStr = formatter.string(from: endTime)

        let timeRange = "\(startStr)-\(endStr)(UTC+8)"

        return (windowType: windowType, timeRange: timeRange)
    }

    private struct ServiceUsageInput {
        let serviceType: String
        let isWebPercentSchema: Bool
        let windowTypeOverride: String?
        let total: Int?
        let remaining: Int?
        let remainingPercent: Double?
        let status: Int?
        let start: Int?
        let end: Int?
        let remainsTime: Int?
        let boostPermille: Int?
    }

    private static func makeServiceUsage(_ input: ServiceUsageInput, now: Date) -> MiniMaxServiceUsage? {
        guard !self.isUnavailableQuotaPlaceholder(input) else { return nil }

        let startTime = self.dateFromEpoch(input.start)
        let endTime = self.dateFromEpoch(input.end)
        var (windowType, timeRange) = self.parseWindowInfo(startTime: startTime, endTime: endTime)
        if let windowTypeOverride = input.windowTypeOverride { windowType = windowTypeOverride }
        if windowType.lowercased() == "weekly",
           let weeklyRange = self.formatMiniMaxDateTimeRange(startTime: startTime, endTime: endTime)
        {
            timeRange = weeklyRange
        }

        let isUnlimited = self.isUnlimitedQuotaWindow(input, windowType: windowType)
        let resetsAt = isUnlimited ? nil : self.resetsAt(end: endTime, remains: input.remainsTime, now: now)
        let resetDescription = if isUnlimited {
            "Unlimited"
        } else {
            self.resetDescription(
                for: windowType,
                timeRange: timeRange,
                now: now,
                resetsAt: resetsAt)
        }
        let limit: Int
        let usage: Int
        let percent: Double
        if isUnlimited {
            percent = 0
            limit = 0
            usage = 0
        } else if let remainingPercent = input.remainingPercent {
            let quotaLimit = self.percentQuotaLimit(boostPermille: input.boostPermille)
            percent = self.usedPercent(remainingPercent: remainingPercent)
            limit = quotaLimit
            usage = Int((percent * Double(quotaLimit) / 100.0).rounded())
        } else {
            guard let total = input.total, total > 0, let remaining = input.remaining else { return nil }
            let used = max(0, total - remaining)
            percent = Double(used) / Double(total) * 100.0
            limit = total
            usage = used
        }

        return MiniMaxServiceUsage(
            serviceType: input.serviceType,
            windowType: windowType,
            timeRange: timeRange,
            usage: usage,
            limit: limit,
            percent: min(100.0, max(0.0, percent)),
            isUnlimited: isUnlimited,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private static func percentQuotaLimit(boostPermille: Int?) -> Int {
        guard let boostPermille, boostPermille > 0 else { return 100 }
        return max(1, Int((Double(boostPermille) / 10.0).rounded()))
    }

    private static func isUnavailableQuotaPlaceholder(_ input: ServiceUsageInput) -> Bool {
        // Status 3 with an empty quota marks a lane excluded from the subscription, except unlimited weekly text.
        if let windowType = input.windowTypeOverride, self.isUnlimitedQuotaWindow(input, windowType: windowType) {
            return false
        }
        return input.status == 3 &&
            (input.total ?? 0) == 0 &&
            (input.remaining ?? 0) == 0 &&
            (input.remainingPercent.map { $0 >= 100 } ?? false)
    }

    private static func isUnlimitedQuotaWindow(_ input: ServiceUsageInput, windowType: String) -> Bool {
        let normalizedService = input.serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedWindow = windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unlimitedServices = ["text generation", "general"]
        if input.isWebPercentSchema, input.status == 3, unlimitedServices.contains(normalizedService) {
            return true
        }
        return input.status == 3 &&
            unlimitedServices.contains(normalizedService) &&
            normalizedWindow == "weekly" &&
            (input.remainingPercent.map { $0 >= 100 } ?? false)
    }
}
