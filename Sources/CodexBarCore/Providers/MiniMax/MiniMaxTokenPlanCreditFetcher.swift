import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum MiniMaxTokenPlanCreditFetcher {
    static func fetch(
        cookieHeader: String,
        groupID: String?,
        region: MiniMaxAPIRegion,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> Double?
    {
        let url = try self.resolveCreditURL(region: region, environment: environment)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let groupID = groupID?.trimmingCharacters(in: .whitespacesAndNewlines), !groupID.isEmpty {
            request.setValue(groupID, forHTTPHeaderField: "x-group-id")
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        let origin = MiniMaxSubscriptionMetadataFetcher.platformOriginURL(region: region)
        request.setValue(origin.absoluteString, forHTTPHeaderField: "origin")
        request.setValue(origin.absoluteString + "/", forHTTPHeaderField: "referer")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(response.statusCode)")
        }
        return try self.parseBalance(data: response.data)
    }

    static func parseBalance(data: Data) throws -> Double? {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let payload = object as? [String: Any] else {
            throw MiniMaxUsageError.parseFailed("MiniMax token plan credit payload was not an object.")
        }
        try self.validateBaseResponse(in: payload)
        return self.balance(from: payload)
    }

    static func resolveCreditURL(region: MiniMaxAPIRegion, environment: [String: String]) throws -> URL {
        if let rejectedKey = MiniMaxSettingsReader.rejectedEndpointOverrideKey(environment: environment) {
            throw ProviderEndpointOverrideError.minimax(rejectedKey)
        }
        if let override = MiniMaxSettingsReader.tokenPlanCreditURL(environment: environment) {
            return override
        }
        if let host = MiniMaxSettingsReader.hostOverride(environment: environment),
           let hostURL = URL(string: "https://\(host)")?
               .appendingPathComponent("backend/account/token_plan_credit")
        {
            return hostURL
        }
        return region.tokenPlanCreditURL
    }

    private static func validateBaseResponse(in payload: [String: Any]) throws {
        guard let baseResp = payload["base_resp"] as? [String: Any] else { return }
        let status = self.intValue(baseResp["status_code"]) ?? 0
        guard status != 0 else { return }
        let message = (baseResp["status_msg"] as? String) ?? "MiniMax token plan credit error \(status)"
        if status == 1004 || message.lowercased().contains("cookie") || message.lowercased().contains("login") {
            throw MiniMaxUsageError.invalidCredentials
        }
        throw MiniMaxUsageError.apiError(message)
    }

    private static func balance(from payload: [String: Any]) -> Double? {
        if let balance = self.doubleValue(payload["remaining_credits"]), balance >= 0 {
            return balance
        }
        if let breakdown = payload["balance_breakdown"] as? [String: Any],
           let balance = self.doubleValue(breakdown["total_balance"]),
           balance >= 0
        {
            return balance
        }
        if let balance = self.doubleValue(payload["points_balance"]), balance >= 0 {
            return balance
        }
        if let balance = self.doubleValue(payload["total_credits"]),
           let used = self.doubleValue(payload["used_credits"]),
           balance >= used
        {
            return balance - used
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

extension MiniMaxSubscriptionMetadataFetcher {
    static func platformOriginURL(region: MiniMaxAPIRegion) -> URL {
        switch region {
        case .global: URL(string: "https://platform.minimax.io")!
        case .chinaMainland: URL(string: "https://platform.minimaxi.com")!
        }
    }
}
