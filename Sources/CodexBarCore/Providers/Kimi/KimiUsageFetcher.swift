import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.kimiAPI)
    private static let subscriptionGraceSeconds: TimeInterval = 2
    private static let usageURL =
        URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
    private static let subscriptionStatURL =
        URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStat")!

    public static func fetchCodeAPIUsage(
        apiKey: String,
        baseURL: URL = KimiSettingsReader.defaultCodeAPIBaseURL,
        now: Date = Date()) async throws -> KimiUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiAPIError.missingAPIKey
        }

        guard let validatedBaseURL = ProviderEndpointOverrideValidator().validatedURL(baseURL.absoluteString) else {
            throw KimiAPIError.invalidRequest("Kimi Code API base URL must use HTTPS without user info")
        }

        let endpoint = self.codeAPIUsageEndpoint(baseURL: validatedBaseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Kimi Code API returned \(response.statusCode): \(responseBody)")
            throw self.codeAPIError(statusCode: response.statusCode)
        }

        return try self.parseCodeAPIUsage(from: data, now: now)
    }

    static func _parseCodeAPIUsageForTesting(_ data: Data, now: Date = Date()) throws -> KimiUsageSnapshot {
        try self.parseCodeAPIUsage(from: data, now: now)
    }

    static func _codeAPIUsageEndpointForTesting(baseURL: URL) -> URL {
        self.codeAPIUsageEndpoint(baseURL: baseURL)
    }

    static func _codeAPIErrorForTesting(statusCode: Int) -> KimiAPIError {
        self.codeAPIError(statusCode: statusCode)
    }

    public static func fetchUsage(authToken: String, now: Date = Date()) async throws -> KimiUsageSnapshot {
        try await self.fetchUsage(
            authToken: authToken,
            now: now,
            transport: ProviderHTTPClient.shared,
            subscriptionGrace: .seconds(self.subscriptionGraceSeconds))
    }

    static func _fetchUsageForTesting(
        authToken: String,
        now: Date = Date(),
        transport: any ProviderHTTPTransport,
        subscriptionGrace: Duration) async throws -> KimiUsageSnapshot
    {
        try await self.fetchUsage(
            authToken: authToken,
            now: now,
            transport: transport,
            subscriptionGrace: subscriptionGrace)
    }

    private static func fetchUsage(
        authToken: String,
        now: Date,
        transport: any ProviderHTTPTransport,
        subscriptionGrace: Duration) async throws -> KimiUsageSnapshot
    {
        let sessionInfo = self.decodeSessionInfo(from: authToken)

        let subscriptionTask = Task<KimiSubscriptionStatResponse?, Error> {
            try await self.fetchSubscriptionStat(
                authToken: authToken,
                sessionInfo: sessionInfo,
                transport: transport)
        }
        let subscriptionRace = BoundedTaskJoin(sourceTask: subscriptionTask)
        let subscriptionOutcomeTask = Task {
            await subscriptionRace.value(joinGrace: subscriptionGrace)
        }

        let codingUsage: KimiUsage
        do {
            codingUsage = try await withTaskCancellationHandler {
                try await self.fetchRequiredUsage(
                    authToken: authToken,
                    sessionInfo: sessionInfo,
                    transport: transport)
            } onCancel: {
                subscriptionOutcomeTask.cancel()
            }
        } catch {
            subscriptionOutcomeTask.cancel()
            _ = await subscriptionOutcomeTask.value
            throw error
        }

        let subscriptionOutcome = await withTaskCancellationHandler {
            await subscriptionOutcomeTask.value
        } onCancel: {
            subscriptionOutcomeTask.cancel()
        }
        try Task.checkCancellation()

        let subscriptionStat: KimiSubscriptionStatResponse?
        switch subscriptionOutcome {
        case let .value(response):
            subscriptionStat = response
        case .timedOut:
            Self.log.warning("Kimi subscription stat timed out")
            subscriptionStat = nil
        case let .failure(error):
            Self.log.warning("Kimi subscription stat unavailable: \(error.localizedDescription)")
            subscriptionStat = nil
        }

        return KimiUsageSnapshot(
            weekly: codingUsage.detail,
            rateLimit: codingUsage.limits?.first?.detail,
            subscriptionBalance: subscriptionStat?.subscriptionBalance,
            updatedAt: now)
    }

    private static func fetchRequiredUsage(
        authToken: String,
        sessionInfo: SessionInfo?,
        transport: any ProviderHTTPTransport) async throws -> KimiUsage
    {
        var request = self.webRequest(url: self.usageURL, authToken: authToken, sessionInfo: sessionInfo)
        let requestBody = ["scope": ["FEATURE_CODING"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Kimi API returned \(response.statusCode): \(responseBody)")

            if response.statusCode == 401 {
                throw KimiAPIError.invalidToken
            }
            if response.statusCode == 403 {
                throw KimiAPIError.invalidToken
            }
            if response.statusCode == 400 {
                throw KimiAPIError.invalidRequest("Bad request")
            }
            throw KimiAPIError.apiError("HTTP \(response.statusCode)")
        }

        let usageResponse = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        guard let codingUsage = usageResponse.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw KimiAPIError.parseFailed("FEATURE_CODING scope not found in response")
        }

        return codingUsage
    }

    private static func parseCodeAPIUsage(from data: Data, now: Date) throws -> KimiUsageSnapshot {
        let response = try JSONDecoder().decode(KimiCodeAPIUsageResponse.self, from: data)
        return KimiUsageSnapshot(
            weekly: response.usage,
            rateLimit: response.limits?.first?.detail,
            updatedAt: now)
    }

    private static func codeAPIUsageEndpoint(baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "coding/v1" || normalizedPath.hasSuffix("/coding/v1") {
            return baseURL.appendingPathComponent("usages")
        }
        if normalizedPath == "coding" || normalizedPath.hasSuffix("/coding") {
            return baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("usages")
        }

        return baseURL
            .appendingPathComponent("coding")
            .appendingPathComponent("v1")
            .appendingPathComponent("usages")
    }

    private static func fetchSubscriptionStat(
        authToken: String,
        sessionInfo: SessionInfo?,
        transport: any ProviderHTTPTransport) async throws -> KimiSubscriptionStatResponse?
    {
        var request = self.webRequest(url: self.subscriptionStatURL, authToken: authToken, sessionInfo: sessionInfo)
        request.httpBody = Data("{}".utf8)

        do {
            let response = try await transport.response(for: request)
            guard response.statusCode == 200 else {
                Self.log.warning("Kimi subscription stat returned \(response.statusCode)")
                return nil
            }
            return try JSONDecoder().decode(KimiSubscriptionStatResponse.self, from: response.data)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            Self.log.warning("Kimi subscription stat unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private static func webRequest(url: URL, authToken: String, sessionInfo: SessionInfo?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")

        if let deviceId = sessionInfo?.deviceId {
            request.setValue(deviceId, forHTTPHeaderField: "x-msh-device-id")
        }
        if let sessionId = sessionInfo?.sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "x-msh-session-id")
        }
        if let trafficId = sessionInfo?.trafficId {
            request.setValue(trafficId, forHTTPHeaderField: "x-traffic-id")
        }
        return request
    }

    private static func codeAPIError(statusCode: Int) -> KimiAPIError {
        switch statusCode {
        case 400:
            .invalidRequest("Bad request")
        case 401:
            .invalidAPIKey
        case 403:
            .apiError("HTTP 403 (permission or quota denied)")
        default:
            .apiError("HTTP \(statusCode)")
        }
    }

    private static func decodeSessionInfo(from jwt: String) -> SessionInfo? {
        let parts = jwt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else { return nil }

        // Convert base64url to base64 for JWT decoding
        // base64url uses - and _ instead of + and /
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        while payload.count % 4 != 0 {
            payload += "="
        }

        guard let payloadData = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        return SessionInfo(
            deviceId: json["device_id"] as? String,
            sessionId: json["ssid"] as? String,
            trafficId: json["sub"] as? String)
    }

    private struct SessionInfo {
        let deviceId: String?
        let sessionId: String?
        let trafficId: String?
    }
}
