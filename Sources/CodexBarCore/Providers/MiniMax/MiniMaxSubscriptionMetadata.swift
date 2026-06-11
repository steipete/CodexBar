import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MiniMaxSubscriptionMetadata: Equatable {
    let planName: String?
    let subscriptionExpiresAt: Date?
    let subscriptionRenewsAt: Date?
}

enum MiniMaxSubscriptionMetadataFetcher {
    private static let comboPath = "v1/api/openplatform/charge/combo/cycle_audio_resource_package"

    static func fetch(
        cookieHeader: String,
        groupID: String?,
        region: MiniMaxAPIRegion,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> MiniMaxSubscriptionMetadata
    {
        let url = try self.resolveComboURL(region: region, environment: environment)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let groupID = groupID?.trimmingCharacters(in: .whitespacesAndNewlines), !groupID.isEmpty {
            request.setValue(groupID, forHTTPHeaderField: "x-group-id")
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue(self.platformOrigin(region: region).absoluteString, forHTTPHeaderField: "origin")
        request.setValue(self.platformOrigin(region: region).absoluteString + "/", forHTTPHeaderField: "referer")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 { throw MiniMaxUsageError.invalidCredentials }
            throw MiniMaxUsageError.apiError("HTTP \(response.statusCode)")
        }
        return try self.parse(data: response.data)
    }

    static func parse(data: Data) throws -> MiniMaxSubscriptionMetadata {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        try self.validateBaseResponse(in: object)
        let planName = self.findPlanName(in: object)
        let subscriptionExpiresAt = self.findDate(
            in: object,
            keys: ["current_subscribe_end_time_ts", "current_subscribe_end_time"])
        let subscriptionRenewsAt = self.findDate(
            in: object,
            keys: ["renewal_trigger_time_ts", "renewal_date"])
        guard planName != nil || subscriptionExpiresAt != nil || subscriptionRenewsAt != nil else {
            throw MiniMaxUsageError.parseFailed("MiniMax combo metadata did not include subscription metadata.")
        }
        return MiniMaxSubscriptionMetadata(
            planName: planName,
            subscriptionExpiresAt: subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionRenewsAt)
    }

    static func resolveComboURL(region: MiniMaxAPIRegion, environment: [String: String]) throws -> URL {
        if let rejectedKey = MiniMaxSettingsReader.rejectedEndpointOverrideKey(environment: environment) {
            throw ProviderEndpointOverrideError.minimax(rejectedKey)
        }
        let baseURL = MiniMaxSettingsReader.hostOverride(environment: environment)
            .map { "https://\($0)" } ?? self.defaultWebHost(region: region)
        guard var components = URLComponents(string: baseURL),
              components.host?.isEmpty == false
        else {
            throw MiniMaxUsageError.apiError("MiniMax combo metadata host is invalid.")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw MiniMaxUsageError.apiError("MiniMax combo metadata host must use HTTPS.")
        }
        components.path = "/" + Self.comboPath
        components.queryItems = [
            URLQueryItem(name: "biz_line", value: "2"),
            URLQueryItem(name: "cycle_type", value: "3"),
            URLQueryItem(name: "resource_package_type", value: "7"),
        ]
        guard let url = components.url else {
            throw MiniMaxUsageError.apiError("MiniMax combo metadata host is invalid.")
        }
        return url
    }

    private static func validateBaseResponse(in object: Any) throws {
        guard let root = object as? [String: Any],
              let baseResp = root["base_resp"] as? [String: Any]
        else { return }
        let status = self.intValue(baseResp["status_code"]) ?? 0
        guard status != 0 else { return }
        let message = (baseResp["status_msg"] as? String) ?? "MiniMax combo metadata error \(status)"
        if status == 1004 || message.lowercased().contains("cookie") {
            throw MiniMaxUsageError.invalidCredentials
        }
        throw MiniMaxUsageError.apiError(message)
    }

    private static func findPlanName(in object: Any) -> String? {
        let currentSubscriptionStrings = self.collectCurrentSubscriptionStrings(in: object)
        if let tokenPlan = self.bestPlanName(in: currentSubscriptionStrings) {
            return tokenPlan
        }

        let strings = self.collectStrings(in: object)
        if let tokenPlan = self.bestPlanName(in: strings) {
            return tokenPlan
        }

        return nil
    }

    private static func bestPlanName(in strings: [String]) -> String? {
        let tokenPlans = strings.compactMap { value -> (rank: Int, value: String)? in
            guard let rank = self.tokenPlanRank(value) else { return nil }
            return (rank, value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let tokenPlan = tokenPlans.min(by: { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.value.count < rhs.value.count : lhs.rank < rhs.rank
        }) {
            return tokenPlan.value
        }
        return strings.first { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["plus", "max", "ultra"].contains(cleaned.lowercased())
        }
    }

    private static func collectCurrentSubscriptionStrings(in object: Any) -> [String] {
        guard let dictionary = object as? [String: Any] else {
            if let array = object as? [Any] {
                return array.flatMap(self.collectCurrentSubscriptionStrings(in:))
            }
            return []
        }

        return dictionary.flatMap { key, value in
            let lowercasedKey = key.lowercased()
            let stringsForCurrentField: [String] = if lowercasedKey == "current_subscribe" ||
                lowercasedKey == "current_subscription" ||
                lowercasedKey.contains("current_subscribe") ||
                lowercasedKey.contains("current_subscription") ||
                lowercasedKey.contains("current_plan")
            {
                self.collectStrings(in: value)
            } else {
                []
            }
            return stringsForCurrentField + self.collectCurrentSubscriptionStrings(in: value)
        }
    }

    private static func tokenPlanRank(_ value: String) -> Int? {
        let lower = value.lowercased()
        if lower.contains("tokenplanplus") { return 0 }
        if lower.contains("tokenplanmax") { return 1 }
        if lower.contains("tokenplanultra") { return 2 }
        if lower.contains("token plan"), lower.contains("plus") || lower.contains("max") || lower.contains("ultra") {
            return 3
        }
        return nil
    }

    private static func collectStrings(in object: Any) -> [String] {
        if let string = object as? String { return [string] }
        if let array = object as? [Any] { return array.flatMap(self.collectStrings(in:)) }
        if let dictionary = object as? [String: Any] {
            return dictionary.sorted { $0.key < $1.key }.flatMap { self.collectStrings(in: $0.value) }
        }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func findDate(in object: Any, keys: [String]) -> Date? {
        keys.lazy.compactMap { key in
            self.findValue(forKey: key, in: object).flatMap(self.dateValue(from:))
        }.first
    }

    private static func findValue(forKey key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] { return value }
            for nested in dictionary.values {
                if let value = self.findValue(forKey: key, in: nested) {
                    return value
                }
            }
        }
        if let array = object as? [Any] {
            for nested in array {
                if let value = self.findValue(forKey: key, in: nested) {
                    return value
                }
            }
        }
        return nil
    }

    private static func dateValue(from value: Any) -> Date? {
        if let int = value as? Int {
            return self.dateValue(fromNumber: Double(int))
        }
        if let double = value as? Double {
            return self.dateValue(fromNumber: double)
        }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numeric = Double(trimmed) {
            return self.dateValue(fromNumber: numeric)
        }
        return self.dateFromMonthDayYear(trimmed)
    }

    private static func dateValue(fromNumber value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func dateFromMonthDayYear(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.date(from: value)
    }

    private static func defaultWebHost(region: MiniMaxAPIRegion) -> String {
        switch region {
        case .global: "https://www.minimax.io"
        case .chinaMainland: "https://www.minimaxi.com"
        }
    }

    private static func platformOrigin(region: MiniMaxAPIRegion) -> URL {
        switch region {
        case .global: URL(string: "https://platform.minimax.io")!
        case .chinaMainland: URL(string: "https://platform.minimaxi.com")!
        }
    }
}

extension MiniMaxUsageFetcher {
    static func attachingSubscriptionMetadataIfAvailable(
        to snapshot: MiniMaxUsageSnapshot,
        context: WebFetchContext,
        groupID: String?) async throws -> MiniMaxUsageSnapshot
    {
        let resolvedGroupID = groupID ?? MiniMaxCookieHeader.override(from: context.cookie)?.groupID
        guard resolvedGroupID?.isEmpty == false else { return snapshot }
        do {
            let metadata = try await MiniMaxSubscriptionMetadataFetcher.fetch(
                cookieHeader: context.cookie,
                groupID: resolvedGroupID,
                region: context.region,
                environment: context.environment,
                transport: context.transport)
            return snapshot.withSubscriptionMetadata(metadata)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            Self.log.debug("MiniMax subscription metadata unavailable: \(error.localizedDescription)")
            return snapshot
        }
    }
}
