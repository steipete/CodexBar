import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("kimi-api")
    private static let usageURL =
        URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!

    public static func fetchUsage(authToken: String, now: Date = Date()) async throws -> KimiUsageSnapshot {
        // Decode JWT to get session info
        let sessionInfo = self.decodeSessionInfo(from: authToken)

        var request = URLRequest(url: self.usageURL)
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

        // Add session-specific headers from JWT
        if let sessionInfo {
            if let deviceId = sessionInfo.deviceId {
                request.setValue(deviceId, forHTTPHeaderField: "x-msh-device-id")
            }
            if let sessionId = sessionInfo.sessionId {
                request.setValue(sessionId, forHTTPHeaderField: "x-msh-session-id")
            }
            if let trafficId = sessionInfo.trafficId {
                request.setValue(trafficId, forHTTPHeaderField: "x-traffic-id")
            }
        }

        let requestBody = ["scope": ["FEATURE_CODING"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KimiAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Kimi API returned \(httpResponse.statusCode): \(responseBody)")

            if httpResponse.statusCode == 401 {
                throw KimiAPIError.invalidToken
            }
            if httpResponse.statusCode == 403 {
                throw KimiAPIError.invalidToken
            }
            if httpResponse.statusCode == 400 {
                throw KimiAPIError.invalidRequest("Bad request")
            }
            throw KimiAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let usageResponse = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        guard let codingUsage = usageResponse.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw KimiAPIError.parseFailed("FEATURE_CODING scope not found in response")
        }

        return KimiUsageSnapshot(
            weekly: codingUsage.detail,
            rateLimit: codingUsage.limits?.first?.detail,
            updatedAt: now)
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
