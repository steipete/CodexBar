import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Cloud Code API Client

public struct AntigravityCloudCodeClient: Sendable {
    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let userAgent = "antigravity"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    private static let metadata: [String: String] = [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    ]

    private let storage: AntigravityOAuthStorage

    public init(storage: AntigravityOAuthStorage = AntigravityOAuthStorage()) {
        self.storage = storage
    }

    // MARK: - Public API

    /// Fetch quota from the Google Cloud Code API.
    /// Handles token refresh, project ID resolution, and model parsing.
    public func fetchQuota(timeout: TimeInterval = 15.0) async throws -> AntigravityStatusSnapshot {
        var tokens = try await self.getValidTokens(timeout: timeout)

        // Step 1: Ensure we have a project ID
        var projectId = tokens.projectId
        if projectId == nil {
            Self.log.debug("No cached project ID, calling loadCodeAssist...")
            let codeAssistData = try await self.request(
                path: "/v1internal:loadCodeAssist",
                body: ["metadata": Self.metadata],
                accessToken: tokens.accessToken,
                timeout: timeout)
            projectId = Self.parseProjectId(from: codeAssistData)

            if let projectId {
                Self.log.debug("Resolved project ID", metadata: ["projectId": projectId])
                let updated = AntigravityOAuthTokens(
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    expiresAt: tokens.expiresAt,
                    email: tokens.email,
                    projectId: projectId)
                try? self.storage.saveTokens(updated)
                tokens = updated
            }
        }

        // Step 2: Fetch available models with quota info
        var body: [String: Any] = [:]
        if let projectId {
            body["project"] = projectId
        }

        let modelsData = try await self.request(
            path: "/v1internal:fetchAvailableModels",
            body: body,
            accessToken: tokens.accessToken,
            timeout: timeout)

        var snapshot = try Self.parseModelsResponse(modelsData)

        // Attach email from tokens
        snapshot = AntigravityStatusSnapshot(
            modelQuotas: snapshot.modelQuotas,
            accountEmail: tokens.email ?? snapshot.accountEmail,
            accountPlan: snapshot.accountPlan)

        return snapshot
    }

    // MARK: - Token Management

    private func getValidTokens(timeout: TimeInterval) async throws -> AntigravityOAuthTokens {
        guard var tokens = self.storage.loadTokens() else {
            throw AntigravityOAuthError.authenticationFailed(
                "Not logged in. Open CodexBar settings → Antigravity → Sign In.")
        }

        if tokens.isExpired {
            Self.log.info("Antigravity access token expired, refreshing...")
            let refreshed = try await AntigravityTokenRefresher.refresh(
                refreshToken: tokens.refreshToken,
                timeout: timeout)
            // Preserve email and projectId from the existing tokens
            tokens = AntigravityOAuthTokens(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                email: tokens.email,
                projectId: tokens.projectId)
            try self.storage.saveTokens(tokens)
        }

        return tokens
    }

    // MARK: - Parsing

    /// Parse the `fetchAvailableModels` response into an `AntigravityStatusSnapshot`.
    public static func parseModelsResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let response = try JSONDecoder().decode(FetchModelsResponse.self, from: data)
        let models = (response.models ?? [:]).compactMap { key, value -> AntigravityModelQuota? in
            guard let quota = value.quotaInfo else { return nil }
            let resetDate = quota.resetTime.flatMap { ISO8601DateFormatter().date(from: $0) }
            return AntigravityModelQuota(
                label: value.displayName ?? key,
                modelId: key,
                remainingFraction: quota.remainingFraction,
                resetTime: resetDate,
                resetDescription: nil)
        }
        return AntigravityStatusSnapshot(
            modelQuotas: models,
            accountEmail: nil,
            accountPlan: nil)
    }

    /// Extract project ID from the `loadCodeAssist` response.
    public static func parseProjectId(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Case 1: String value
        if let project = json["cloudaicompanionProject"] as? String {
            let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Case 2: Object with { id: "..." } or { projectId: "..." }
        if let projectObj = json["cloudaicompanionProject"] as? [String: Any] {
            let rawProjectId = (projectObj["id"] as? String) ?? (projectObj["projectId"] as? String)
            let trimmed = rawProjectId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    // MARK: - HTTP

    private func request(
        path: String,
        body: [String: Any],
        accessToken: String,
        timeout: TimeInterval) async throws -> Data
    {
        guard let url = URL(string: "\(Self.baseURL)\(path)") else {
            throw AntigravityOAuthError.authenticationFailed("Invalid URL: \(path)")
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.authenticationFailed("Invalid response from \(path)")
        }

        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            Self.log.warning("Auth failure from Cloud Code API", metadata: ["status": "\(http.statusCode)"])
            throw AntigravityOAuthError.authenticationFailed("HTTP \(http.statusCode) — token may be revoked")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Cloud Code API error", metadata: ["status": "\(http.statusCode)", "body": body])
            throw AntigravityOAuthError.authenticationFailed("API error HTTP \(http.statusCode)")
        }
    }
}

// MARK: - Response Types

private struct FetchModelsResponse: Decodable {
    let models: [String: ModelEntry]?
}

private struct ModelEntry: Decodable {
    let displayName: String?
    let quotaInfo: ModelQuotaEntry?
}

private struct ModelQuotaEntry: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let isExhausted: Bool?
}
