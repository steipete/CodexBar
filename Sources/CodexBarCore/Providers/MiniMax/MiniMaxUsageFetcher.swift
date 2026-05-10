import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxUsageFetcher: Sendable {
    static let log = CodexBarLog.logger(LogCategories.minimaxUsage)
    private static let codingPlanPath = "user-center/payment/coding-plan"
    private static let codingPlanQuery = "cycle_type=3"
    private static let codingPlanRemainsPath = "v1/api/openplatform/coding_plan/remains"
    private struct RemainsContext {
        let authorizationToken: String?
        let groupID: String?
    }

    public static func fetchUsage(
        cookieHeader: String,
        authorizationToken: String? = nil,
        groupID: String? = nil,
        region: MiniMaxAPIRegion = .global,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> MiniMaxUsageSnapshot
    {
        guard let cookie = MiniMaxCookieHeader.normalized(from: cookieHeader) else {
            throw MiniMaxUsageError.invalidCredentials
        }

        do {
            return try await self.fetchCodingPlanHTML(
                cookie: cookie,
                authorizationToken: authorizationToken,
                region: region,
                environment: environment,
                now: now)
        } catch let error as MiniMaxUsageError {
            if case .parseFailed = error {
                Self.log.debug("MiniMax coding plan HTML parse failed, trying remains API")
                return try await self.fetchCodingPlanRemains(
                    cookie: cookie,
                    remainsContext: RemainsContext(
                        authorizationToken: authorizationToken,
                        groupID: groupID),
                    region: region,
                    environment: environment,
                    now: now)
            }
            throw error
        }
    }

    public static func fetchUsage(
        apiToken: String,
        region: MiniMaxAPIRegion = .global,
        now: Date = Date(),
        session: URLSession = .shared) async throws -> MiniMaxUsageSnapshot
    {
        let cleaned = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MiniMaxUsageError.invalidCredentials
        }

        // Historically, MiniMax API token fetching used a China endpoint by default in some configurations. If the
        // user has no persisted region and we default to `.global`, retry the China endpoint when the global host
        // rejects the token so upgrades don't regress existing setups.
        if region != .global {
            return try await self.fetchUsageOnce(apiToken: cleaned, region: region, now: now, session: session)
        }

        do {
            return try await self.fetchUsageOnce(apiToken: cleaned, region: .global, now: now, session: session)
        } catch let error as MiniMaxUsageError {
            guard case .invalidCredentials = error else { throw error }
            Self.log.debug("MiniMax API token rejected for global host, retrying China mainland host")
            do {
                return try await self.fetchUsageOnce(
                    apiToken: cleaned,
                    region: .chinaMainland,
                    now: now,
                    session: session)
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
        session: URLSession) async throws -> MiniMaxUsageSnapshot
    {
        var request = URLRequest(url: region.apiRemainsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodexBar", forHTTPHeaderField: "MM-API-Source")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
        if let services = snapshot.services, !services.isEmpty {
            Self.log.debug("MiniMax multi-service response detected: \(services.count) services")
        }
        return snapshot
    }

    private static func fetchCodingPlanHTML(
        cookie: String,
        authorizationToken: String?,
        region: MiniMaxAPIRegion,
        environment: [String: String],
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        let url = self.resolveCodingPlanURL(region: region, environment: environment)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        let acceptHeader = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        request.setValue(acceptHeader, forHTTPHeaderField: "accept")
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        let origin = self.originURL(from: url)
        request.setValue(origin.absoluteString, forHTTPHeaderField: "origin")
        request.setValue(
            self.resolveCodingPlanRefererURL(region: region, environment: environment).absoluteString,
            forHTTPHeaderField: "referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("application/json")
        {
            let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
            if let services = snapshot.services, !services.isEmpty {
                Self.log.debug("MiniMax multi-service response detected: \(services.count) services")
            }
            return snapshot
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        if html.contains("__NEXT_DATA__") {
            Self.log.debug("MiniMax coding plan HTML contains __NEXT_DATA__")
        }
        if self.looksSignedOut(html: html) {
            throw MiniMaxUsageError.invalidCredentials
        }
        return try MiniMaxUsageParser.parse(html: html, now: now)
    }

    private static func fetchCodingPlanRemains(
        cookie: String,
        remainsContext: RemainsContext,
        region: MiniMaxAPIRegion,
        environment: [String: String],
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        let baseRemainsURL = self.resolveRemainsURL(region: region, environment: environment)
        let remainsURL = self.appendGroupID(remainsContext.groupID, to: baseRemainsURL)
        var request = URLRequest(url: remainsURL)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let authorizationToken = remainsContext.authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        let acceptHeader = "application/json, text/plain, */*"
        request.setValue(acceptHeader, forHTTPHeaderField: "accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        let origin = self.originURL(from: baseRemainsURL)
        request.setValue(origin.absoluteString, forHTTPHeaderField: "origin")
        request.setValue(
            self.resolveCodingPlanRefererURL(region: region, environment: environment).absoluteString,
            forHTTPHeaderField: "referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("application/json")
        {
            let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
            if let services = snapshot.services, !services.isEmpty {
                Self.log.debug("MiniMax multi-service response detected: \(services.count) services")
            }
            return snapshot
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        if self.looksSignedOut(html: html) {
            throw MiniMaxUsageError.invalidCredentials
        }
        return try MiniMaxUsageParser.parse(html: html, now: now)
    }

    private static func appendGroupID(_ groupID: String?, to url: URL) -> URL {
        guard let groupID, !groupID.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
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
           let hostURL = self.url(from: host, path: Self.codingPlanPath, query: Self.codingPlanQuery)
        {
            return hostURL
        }
        return region.codingPlanURL
    }

    static func resolveCodingPlanRefererURL(
        region: MiniMaxAPIRegion,
        environment: [String: String]) -> URL
    {
        if let override = MiniMaxSettingsReader.codingPlanURL(environment: environment) {
            if var components = URLComponents(url: override, resolvingAgainstBaseURL: false) {
                components.query = nil
                return components.url ?? override
            }
            return override
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment),
           let hostURL = self.url(from: host, path: Self.codingPlanPath)
        {
            return hostURL
        }
        return region.codingPlanRefererURL
    }

    static func resolveRemainsURL(
        region: MiniMaxAPIRegion,
        environment: [String: String]) -> URL
    {
        if let override = MiniMaxSettingsReader.remainsURL(environment: environment) {
            return override
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment),
           let hostURL = self.url(from: host, path: Self.codingPlanRemainsPath)
        {
            return hostURL
        }
        return region.remainsURL
    }

    static func url(from raw: String, path: String? = nil, query: String? = nil) -> URL? {
        guard let cleaned = MiniMaxSettingsReader.cleaned(raw) else { return nil }

        func compose(_ base: URL) -> URL? {
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            if let path { components.path = "/" + path }
            if let query { components.query = query }
            return components.url
        }

        if let url = URL(string: cleaned), url.scheme != nil {
            if let composed = compose(url) { return composed }
            return url
        }
        guard let base = URL(string: "https://\(cleaned)") else { return nil }
        return compose(base)
    }

    private static func logCodingPlanStatus(payload: MiniMaxCodingPlanPayload) {
        let baseResponse = payload.data.baseResp ?? payload.baseResp
        guard let status = baseResponse?.statusCode else { return }
        let message = baseResponse?.statusMessage ?? ""
        if !message.isEmpty {
            Self.log.debug("MiniMax coding plan status \(status): \(message)")
        } else {
            Self.log.debug("MiniMax coding plan status \(status)")
        }
    }

    private static func looksSignedOut(html: String) -> Bool {
        let lower = self.visibleText(from: html).lowercased()
        return lower.contains("sign in") || lower.contains("log in") || lower.contains("登录") || lower.contains("登入")
    }

    static func _looksSignedOutForTesting(html: String) -> Bool {
        self.looksSignedOut(html: html)
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
    let modelRemains: [MiniMaxModelRemains]

    private enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case currentSubscribeTitle = "current_subscribe_title"
        case planName = "plan_name"
        case comboTitle = "combo_title"
        case currentPlanTitle = "current_plan_title"
        case currentComboCard = "current_combo_card"
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
        self.modelRemains = try (container.decodeIfPresent([MiniMaxModelRemains].self, forKey: .modelRemains)) ?? []
    }
}

struct MiniMaxComboCard: Decodable {
    let title: String?
}

struct MiniMaxModelRemains: Decodable {
    let modelName: String?
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?
    let currentWeeklyTotalCount: Int?
    let currentWeeklyUsageCount: Int?
    let weeklyStartTime: Int?
    let weeklyEndTime: Int?
    let weeklyRemainsTime: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case weeklyRemainsTime = "weekly_remains_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.currentIntervalTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalTotalCount)
        self.currentIntervalUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalUsageCount)
        self.startTime = MiniMaxDecoding.decodeInt(container, forKey: .startTime)
        self.endTime = MiniMaxDecoding.decodeInt(container, forKey: .endTime)
        self.remainsTime = MiniMaxDecoding.decodeInt(container, forKey: .remainsTime)
        self.currentWeeklyTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyTotalCount)
        self.currentWeeklyUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyUsageCount)
        self.weeklyStartTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyStartTime)
        self.weeklyEndTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyEndTime)
        self.weeklyRemainsTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyRemainsTime)
    }
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

enum MiniMaxDecoding {
    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }
        return nil
    }
}

enum MiniMaxUsageParser {
    static func decodePayload(data: Data) throws -> MiniMaxCodingPlanPayload {
        let decoder = JSONDecoder()
        return try decoder.decode(MiniMaxCodingPlanPayload.self, from: data)
    }

    static func decodeMultiServicePayload(data: Data) throws -> MiniMaxMultiServicePayload {
        let decoder = JSONDecoder()
        return try decoder.decode(MiniMaxMultiServicePayload.self, from: data)
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
            // Skip services with no quota (limit = 0)
            guard let modelName = item.modelName,
                  let limit = item.currentIntervalTotalCount,
                  limit > 0,
                  let remaining = item.currentIntervalUsageCount
            else {
                continue
            }

            // Calculate usage and percentage
            // current_interval_usage_count is REMAINING quota (not used)
            let used = max(0, limit - remaining)
            let percent = limit > 0 ? Double(used) / Double(limit) * 100.0 : 0.0

            // Parse time window
            let startTime = self.dateFromEpoch(item.startTime)
            let endTime = self.dateFromEpoch(item.endTime)

            // Determine window type and time range
            let (windowType, timeRange) = self.parseWindowInfo(
                startTime: startTime,
                endTime: endTime,
                now: now)

            // Calculate reset time
            let resetsAt = self.resetsAt(end: endTime, remains: item.remainsTime, now: now)
            let resetDescription = self.resetDescription(
                for: windowType,
                timeRange: timeRange,
                now: now,
                resetsAt: resetsAt)

            // Map model_name to service type identifier
            let serviceTypeIdentifier = self.mapModelNameToServiceType(modelName: modelName)

            let serviceUsage = MiniMaxServiceUsage(
                serviceType: serviceTypeIdentifier,
                windowType: windowType,
                timeRange: timeRange,
                usage: used,
                limit: limit,
                percent: min(100.0, max(0.0, percent)),
                resetsAt: resetsAt,
                resetDescription: resetDescription)
            services.append(serviceUsage)
        }

        // Use first service for backward compatibility fields
        let first = payload.data.modelRemains.first
        let total = first?.currentIntervalTotalCount
        let remaining = first?.currentIntervalUsageCount
        let usedPercent = self.usedPercent(total: total, remaining: remaining)

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
            services: services.isEmpty ? nil : services)
    }

    private static func usedPercent(total: Int?, remaining: Int?) -> Double? {
        guard let total, total > 0, let remaining else { return nil }
        let used = max(0, total - remaining)
        let percent = Double(used) / Double(total) * 100
        return min(100, max(0, percent))
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
        let candidates = [
            data.currentSubscribeTitle,
            data.planName,
            data.comboTitle,
            data.currentPlanTitle,
            data.currentComboCard?.title,
        ].compactMap(\.self)

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func parsePlanName(html: String, text: String) -> String? {
        let candidates = [
            self.extractFirst(pattern: #"(?i)"planName"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)"plan"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)"packageName"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)Coding\s*Plan\s*([A-Za-z0-9][A-Za-z0-9\s._-]{0,32})"#, text: text),
        ].compactMap(\.self)

        for candidate in candidates {
            let cleaned = UsageFormatter.cleanPlanName(candidate)
            let trimmed = cleaned
                .replacingOccurrences(
                    of: #"(?i)\s+available\s+usage.*$"#,
                    with: "",
                    options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

        if normalized["model_remains"] == nil, let value = normalized["modelRemains"] {
            normalized["model_remains"] = value
        }
        if normalized["current_subscribe_title"] == nil, let value = normalized["currentSubscribeTitle"] {
            normalized["current_subscribe_title"] = value
        }
        if normalized["plan_name"] == nil, let value = normalized["planName"] {
            normalized["plan_name"] = value
        }
        if normalized["combo_title"] == nil, let value = normalized["comboTitle"] {
            normalized["combo_title"] = value
        }
        if normalized["current_plan_title"] == nil, let value = normalized["currentPlanTitle"] {
            normalized["current_plan_title"] = value
        }
        if normalized["current_combo_card"] == nil, let value = normalized["currentComboCard"] {
            normalized["current_combo_card"] = value
        }
        if normalized["base_resp"] == nil, let value = normalized["baseResp"] {
            normalized["base_resp"] = value
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
        guard let idRange = data.range(of: self.nextDataNeedle) else { return nil }
        guard let openTagEnd = data[idRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        let contentStart = data.index(after: openTagEnd)
        guard let closeRange = data.range(
            of: self.scriptCloseNeedle,
            options: [],
            in: contentStart..<data.endIndex)
        else { return nil }
        let rawData = data[contentStart..<closeRange.lowerBound]
        let trimmed = self.trimASCIIWhitespace(Data(rawData))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimASCIIWhitespace(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var start = data.startIndex
        var end = data.endIndex

        while start < end, self.isASCIIWhitespace(data[start]) {
            start = data.index(after: start)
        }
        while end > start {
            let prev = data.index(before: end)
            if self.isASCIIWhitespace(data[prev]) {
                end = prev
            } else {
                break
            }
        }
        return data.subdata(in: start..<end)
    }

    private static func isASCIIWhitespace(_ value: UInt8) -> Bool {
        switch value {
        case 9, 10, 13, 32:
            true
        default:
            false
        }
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
        guard prompts > 0 else { return nil }

        guard let duration = Double(durationRaw) else { return nil }
        let windowMinutes = self.minutes(from: duration, unit: unitRaw)
        guard windowMinutes > 0 else { return nil }
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

    private static func minutes(from value: Double, unit: String) -> Int {
        let lower = unit.lowercased()
        if lower.hasPrefix("d") { return Int((value * 24 * 60).rounded()) }
        if lower.hasPrefix("h") { return Int((value * 60).rounded()) }
        if lower.hasPrefix("m") { return Int(value.rounded()) }
        if lower.hasPrefix("s") { return max(1, Int((value / 60).rounded())) }
        return 0
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
        let payload = try self.decodeMultiServicePayload(data: data)

        guard !payload.data.services.isEmpty else {
            return nil
        }

        var services: [MiniMaxServiceUsage] = []
        for item in payload.data.services {
            guard let serviceType = item.serviceType,
                  let windowType = item.windowType,
                  let timeRange = item.timeRange,
                  let usage = item.usage,
                  let limit = item.limit
            else {
                continue
            }

            var percent = item.percent ?? 0.0
            if item.percent == nil, limit > 0 {
                percent = Double(usage) / Double(limit) * 100.0
            }

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
        endTime: Date?,
        now: Date) -> (windowType: String, timeRange: String)
    {
        guard let startTime, let endTime else {
            return (windowType: "Unknown", timeRange: "N/A")
        }

        let durationSeconds = endTime.timeIntervalSince(startTime)
        let durationHours = durationSeconds / 3600

        // Determine window type based on duration
        let windowType = if durationHours >= 23, durationHours <= 25 {
            "Today"
        } else if durationHours >= 4, durationHours <= 6 {
            "5 hours"
        } else if durationHours >= 1, durationHours < 23 {
            "\(Int(durationHours)) hours"
        } else {
            "Custom"
        }

        // Format time range
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let startStr = formatter.string(from: startTime)
        let endStr = formatter.string(from: endTime)

        let timeRange = "\(startStr)-\(endStr)(UTC+8)"

        return (windowType: windowType, timeRange: timeRange)
    }

    private static func mapModelNameToServiceType(modelName: String) -> String {
        let lower = modelName.lowercased()

        // Text Generation (文本生成): M2.7, M2.7-highspeed, MiniMax-M*, etc.
        if lower.contains("minimax-m") {
            return "Text Generation"
        }

        // Text to Speech (语音合成): speech-hd, Speech 2.8, etc.
        if lower.contains("speech") {
            return "Text to Speech"
        }

        // Image to Video Fast (图生视频 Fast): Hailuo-2.3-Fast
        if lower.contains("hailuo"), lower.contains("fast") {
            return "Image to Video"
        }

        // Text to Video (文生视频): Hailuo-2.3 (non-Fast)
        if lower.contains("hailuo") {
            return "Text to Video"
        }

        // Image Generation (图像生成): image-01, image-02, etc.
        if lower.hasPrefix("image-") {
            return "Image Generation"
        }

        // Music Generation (音乐生成): music-2.5, etc.
        if lower.contains("music") {
            return "Music Generation"
        }

        // Default: use model name as-is
        return modelName
    }
}

public enum MiniMaxUsageError: LocalizedError, Sendable, Equatable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "MiniMax credentials are invalid or expired."
        case let .networkError(message):
            "MiniMax network error: \(message)"
        case let .apiError(message):
            "MiniMax API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse MiniMax coding plan: \(message)"
        }
    }
}
