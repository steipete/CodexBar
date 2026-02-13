import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.minimaxUsage)
    private static let codingPlanPath = "user-center/payment/coding-plan"
    private static let codingPlanQuery = "cycle_type=3"
    private static let codingPlanRemainsPath = "v1/api/openplatform/coding_plan/remains"
    private struct RemainsContext: Sendable {
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
        now: Date = Date()) async throws -> MiniMaxUsageSnapshot
    {
        let cleaned = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw MiniMaxUsageError.invalidCredentials
        }

        // Historically, MiniMax API token fetching used a China endpoint by default in some configurations. If the
        // user has no persisted region and we default to `.global`, retry the China endpoint when the global host
        // rejects the token so upgrades don't regress existing setups.
        if region != .global {
            return try await self.fetchUsageOnce(apiToken: cleaned, region: region, now: now)
        }

        do {
            return try await self.fetchUsageOnce(apiToken: cleaned, region: .global, now: now)
        } catch let error as MiniMaxUsageError {
            guard case .invalidCredentials = error else { throw error }
            Self.log.debug("MiniMax API token rejected for global host, retrying China mainland host")
            do {
                return try await self.fetchUsageOnce(apiToken: cleaned, region: .chinaMainland, now: now)
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
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        var request = URLRequest(url: region.apiRemainsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodexBar", forHTTPHeaderField: "MM-API-Source")

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

        return try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
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
            return try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
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
            let payload = try MiniMaxUsageParser.decodePayload(data: data)
            self.logCodingPlanStatus(payload: payload)
            return try MiniMaxUsageParser.parseCodingPlanRemains(payload: payload, now: now)
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
        let lower = html.lowercased()
        return lower.contains("sign in") || lower.contains("log in") || lower.contains("登录") || lower.contains("登入")
    }
}

struct MiniMaxCodingPlanPayload: Decodable, Sendable {
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

struct MiniMaxCodingPlanData: Decodable, Sendable {
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

struct MiniMaxComboCard: Decodable, Sendable {
    let title: String?
}

struct MiniMaxModelRemains: Decodable, Sendable {
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?

    private enum CodingKeys: String, CodingKey {
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentIntervalTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalTotalCount)
        self.currentIntervalUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalUsageCount)
        self.startTime = MiniMaxDecoding.decodeInt(container, forKey: .startTime)
        self.endTime = MiniMaxDecoding.decodeInt(container, forKey: .endTime)
        self.remainsTime = MiniMaxDecoding.decodeInt(container, forKey: .remainsTime)
    }
}

struct MiniMaxBaseResponse: Decodable, Sendable {
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

    static func decodePayload(json: [String: Any]) throws -> MiniMaxCodingPlanPayload {
        let normalized = self.normalizeCodingPlanPayload(json)
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [])
        return try self.decodePayload(data: data)
    }

    static func parseCodingPlanRemains(data: Data, now: Date = Date()) throws -> MiniMaxUsageSnapshot {
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

        guard let first = payload.data.modelRemains.first else {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        let total = first.currentIntervalTotalCount
        let remaining = first.currentIntervalUsageCount
        let usedPercent = self.usedPercent(total: total, remaining: remaining)

        let windowMinutes = self.windowMinutes(
            start: self.dateFromEpoch(first.startTime),
            end: self.dateFromEpoch(first.endTime))

        let resetsAt = self.resetsAt(
            end: self.dateFromEpoch(first.endTime),
            remains: first.remainsTime,
            now: now)

        let planName = self.parsePlanName(data: payload.data)

        if planName == nil, total == nil, usedPercent == nil {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

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
            updatedAt: now)
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
            formatter.timeZone = TimeZone(identifier: tzHint)
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
