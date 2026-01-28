import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityCloudCodeConfig {
    public static let baseURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com",
    ]

    public static let fetchAvailableModelsPath = "/v1internal:fetchAvailableModels"
    public static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    public static let onboardUserPath = "/v1internal:onboardUser"
    public static let userAgent = "antigravity"

    public static let metadata: [String: String] = [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    ]

    public static let defaultAttempts = 2
    public static let backoffBaseMs = 500
    public static let backoffMaxMs = 4000
}

public struct AntigravityCloudCodeQuota: Sendable {
    public let models: [AntigravityModelQuota]
    public let email: String?
    public let projectId: String?
}

public struct AntigravityProjectInfo: Sendable {
    public let projectId: String?
    public let tierId: String?
}

public enum AntigravityCloudCodeClient {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)
    private static let httpTimeout: TimeInterval = 15.0

    public static func fetchQuota(accessToken: String, projectId: String? = nil) async throws -> AntigravityCloudCodeQuota {
        try await self.requestWithRetry { baseURL in
            try await self.fetchQuotaFromEndpoint(
                baseURL: baseURL,
                accessToken: accessToken,
                projectId: projectId)
        }
    }

    public static func loadProjectInfo(accessToken: String) async throws -> AntigravityProjectInfo {
        try await self.requestWithRetry { baseURL in
            try await self.loadProjectInfoFromEndpoint(baseURL: baseURL, accessToken: accessToken)
        }
    }

    private static func requestWithRetry<T>(
        _ operation: (String) async throws -> T) async throws -> T
    {
        var lastError: Error?

        for attempt in 1...AntigravityCloudCodeConfig.defaultAttempts {
            if attempt > 1 {
                let delay = self.getBackoffDelay(attempt: attempt)
                self.log.info("Cloud Code retry round \(attempt)/\(AntigravityCloudCodeConfig.defaultAttempts) in \(delay)ms")
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }

            for baseURL in AntigravityCloudCodeConfig.baseURLs {
                do {
                    return try await operation(baseURL)
                } catch let error as AntigravityOAuthCredentialsError {
                    if case .invalidGrant = error {
                        throw error
                    }
                    lastError = error
                    self.log.debug("Cloud Code request failed (\(baseURL)): \(error.localizedDescription)")
                } catch {
                    lastError = error
                    self.log.debug("Cloud Code request failed (\(baseURL)): \(error.localizedDescription)")
                }
            }
        }

        throw lastError ?? AntigravityOAuthCredentialsError.networkError("All Cloud Code endpoints failed")
    }

    private static func getBackoffDelay(attempt: Int) -> Int {
        let raw = AntigravityCloudCodeConfig.backoffBaseMs * Int(pow(2.0, Double(attempt - 2)))
        let jitter = Int.random(in: 0..<100)
        return min(raw + jitter, AntigravityCloudCodeConfig.backoffMaxMs)
    }

    private static func fetchQuotaFromEndpoint(
        baseURL: String,
        accessToken: String,
        projectId: String?) async throws -> AntigravityCloudCodeQuota
    {
        let urlString = baseURL + AntigravityCloudCodeConfig.fetchAvailableModelsPath
        guard let url = URL(string: urlString) else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid Cloud Code URL")
        }

        var requestBody: [String: Any] = [:]
        if let projectId {
            requestBody["project"] = projectId
        }

        let data = try await self.makeRequest(url: url, body: requestBody, accessToken: accessToken)
        return try self.parseQuotaResponse(data: data)
    }

    private static func loadProjectInfoFromEndpoint(
        baseURL: String,
        accessToken: String) async throws -> AntigravityProjectInfo
    {
        let urlString = baseURL + AntigravityCloudCodeConfig.loadCodeAssistPath
        guard let url = URL(string: urlString) else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid Cloud Code URL")
        }

        let requestBody: [String: Any] = ["metadata": AntigravityCloudCodeConfig.metadata]
        let data = try await self.makeRequest(url: url, body: requestBody, accessToken: accessToken)
        return try self.parseProjectInfoResponse(data: data)
    }

    private static func makeRequest(
        url: URL,
        body: [String: Any],
        accessToken: String) async throws -> Data
    {
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AntigravityCloudCodeConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = self.httpTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthCredentialsError.networkError("Invalid response")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw AntigravityOAuthCredentialsError.invalidGrant
        }

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw AntigravityOAuthCredentialsError.networkError("HTTP \(http.statusCode): \(errorBody)")
        }

        return data
    }

    private static func parseProjectInfoResponse(data: Data) throws -> AntigravityProjectInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid Cloud Code response JSON")
        }

        let projectId = self.extractProjectId(from: json["cloudaicompanionProject"])
        let tierId: String?
        if let paidTier = json["paidTier"] as? [String: Any], let id = paidTier["id"] as? String {
            tierId = id
        } else if let currentTier = json["currentTier"] as? [String: Any], let id = currentTier["id"] as? String {
            tierId = id
        } else {
            tierId = nil
        }

        return AntigravityProjectInfo(projectId: projectId, tierId: tierId)
    }

    private static func extractProjectId(from project: Any?) -> String? {
        if let projectString = project as? String, !projectString.isEmpty {
            return projectString
        }
        if let projectDict = project as? [String: Any], let id = projectDict["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private static func parseQuotaResponse(data: Data) throws -> AntigravityCloudCodeQuota {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid Cloud Code response JSON")
        }

        var models: [AntigravityModelQuota] = []

        if let modelsDict = json["models"] as? [String: [String: Any]] {
            for (modelKey, modelData) in modelsDict {
                if let quota = self.parseModelFromDict(key: modelKey, data: modelData) {
                    models.append(quota)
                }
            }
        }

        return AntigravityCloudCodeQuota(models: models, email: nil, projectId: nil)
    }

    private static func parseModelFromDict(key: String, data: [String: Any]) -> AntigravityModelQuota? {
        let displayName = (data["displayName"] as? String) ?? key
        let modelId = (data["model"] as? String) ?? key

        var remainingFraction: Double?
        var resetTime: Date?

        if let quotaInfo = data["quotaInfo"] as? [String: Any] {
            remainingFraction = quotaInfo["remainingFraction"] as? Double

            if let resetTimeStr = quotaInfo["resetTime"] as? String {
                resetTime = ISO8601DateFormatter().date(from: resetTimeStr)
                if resetTime == nil, let seconds = Double(resetTimeStr) {
                    resetTime = Date(timeIntervalSince1970: seconds)
                }
            }
        }

        return AntigravityModelQuota(
            label: displayName,
            modelId: modelId,
            remainingFraction: remainingFraction,
            resetTime: resetTime,
            resetDescription: nil)
    }
}
