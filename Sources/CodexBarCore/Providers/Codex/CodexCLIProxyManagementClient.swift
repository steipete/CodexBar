import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexCLIProxyError: LocalizedError, Sendable {
    case invalidBaseURL
    case missingManagementKey
    case invalidResponse
    case managementRequestFailed(Int, String?)
    case missingCodexAuth(String?)
    case missingProviderAuth(provider: String, authIndex: String?)
    case apiCallFailed(Int, String?)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return L10n.tr("error.codex.cliproxy.invalid_base_url", fallback: "CLIProxyAPI base URL is invalid.")
        case .missingManagementKey:
            return L10n.tr(
                "error.codex.cliproxy.missing_management_key",
                fallback: "CLIProxy management key is missing. Please set it in Settings > General > CLIProxyAPI.")
        case .invalidResponse:
            return L10n.tr("error.codex.cliproxy.invalid_response", fallback: "CLIProxyAPI returned an invalid response.")
        case let .managementRequestFailed(status, message):
            if let message, !message.isEmpty {
                let format = L10n.tr(
                    "error.codex.cliproxy.management_failed_with_message",
                    fallback: "CLIProxyAPI management API failed (%d): %@")
                return String(format: format, locale: .current, status, message)
            }
            let format = L10n.tr(
                "error.codex.cliproxy.management_failed",
                fallback: "CLIProxyAPI management API failed (%d).")
            return String(format: format, locale: .current, status)
        case let .missingCodexAuth(authIndex):
            if let authIndex, !authIndex.isEmpty {
                let format = L10n.tr(
                    "error.codex.cliproxy.missing_auth_with_index",
                    fallback: "CLIProxyAPI did not find Codex auth_index %@.")
                return String(format: format, locale: .current, authIndex)
            }
            return L10n.tr(
                "error.codex.cliproxy.missing_auth",
                fallback: "CLIProxyAPI has no available Codex auth entry.")
        case let .missingProviderAuth(provider, authIndex):
            if let authIndex, !authIndex.isEmpty {
                let format = L10n.tr(
                    "error.codex.cliproxy.missing_provider_auth_with_index",
                    fallback: "CLIProxyAPI did not find %@ auth_index %@.")
                return String(format: format, locale: .current, provider, authIndex)
            }
            let format = L10n.tr(
                "error.codex.cliproxy.missing_provider_auth",
                fallback: "CLIProxyAPI has no available %@ auth entry.")
            return String(format: format, locale: .current, provider)
        case let .apiCallFailed(status, message):
            if let message, !message.isEmpty {
                let format = L10n.tr(
                    "error.codex.cliproxy.api_call_failed_with_message",
                    fallback: "CLIProxyAPI api-call failed (%d): %@")
                return String(format: format, locale: .current, status, message)
            }
            let format = L10n.tr(
                "error.codex.cliproxy.api_call_failed",
                fallback: "CLIProxyAPI api-call failed (%d).")
            return String(format: format, locale: .current, status)
        case let .decodeFailed(message):
            let format = L10n.tr(
                "error.codex.cliproxy.decode_failed",
                fallback: "Failed to decode CLIProxyAPI response: %@")
            return String(format: format, locale: .current, message)
        }
    }
}

public struct CodexCLIProxyResolvedAuth: Sendable {
    public let authIndex: String
    public let email: String?
    public let chatGPTAccountID: String?
    public let planType: String?
}

public struct CLIProxyGeminiQuotaBucket: Sendable {
    public let modelID: String
    public let remainingFraction: Double
    public let resetTime: Date?

    public init(modelID: String, remainingFraction: Double, resetTime: Date?) {
        self.modelID = modelID
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
    }
}

public struct CLIProxyGeminiQuotaResponse: Sendable {
    public let buckets: [CLIProxyGeminiQuotaBucket]

    public init(buckets: [CLIProxyGeminiQuotaBucket]) {
        self.buckets = buckets
    }
}

private enum CLIProxyAuthProvider: Sendable {
    case codex
    case gemini
    case antigravity

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        }
    }

    var providerValues: Set<String> {
        switch self {
        case .codex: ["codex"]
        case .gemini: ["gemini-cli", "gemini"]
        case .antigravity: ["antigravity"]
        }
    }

    var typeValues: Set<String> {
        switch self {
        case .codex: ["codex"]
        case .gemini: ["gemini-cli", "gemini"]
        case .antigravity: ["antigravity"]
        }
    }

    func matches(provider: String?, type: String?) -> Bool {
        let normalizedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return self.providerValues.contains(normalizedProvider ?? "")
            || self.typeValues.contains(normalizedType ?? "")
    }

    func missingAuthError(authIndex: String?) -> CodexCLIProxyError {
        switch self {
        case .codex:
            return .missingCodexAuth(authIndex)
        case .gemini, .antigravity:
            return .missingProviderAuth(provider: self.displayName, authIndex: authIndex)
        }
    }
}

public struct CodexCLIProxyManagementClient: Sendable {
    private let settings: CodexCLIProxySettings
    private let session: URLSession
    private static let geminiQuotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let geminiLoadCodeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let geminiFallbackProjectID = "just-well-nxk81"
    private static let geminiHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "User-Agent": "google-api-nodejs-client/9.15.1",
        "X-Goog-Api-Client": "gl-node/22.17.0",
        "Client-Metadata": "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI",
    ]

    public init(settings: CodexCLIProxySettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public func resolveCodexAuth() async throws -> CodexCLIProxyResolvedAuth {
        try await self.resolveAuth(for: .codex)
    }

    public func listCodexAuths() async throws -> [CodexCLIProxyResolvedAuth] {
        try await self.listAuths(for: .codex)
    }

    public func resolveGeminiAuth() async throws -> CodexCLIProxyResolvedAuth {
        try await self.resolveAuth(for: .gemini)
    }

    public func listGeminiAuths() async throws -> [CodexCLIProxyResolvedAuth] {
        try await self.listAuths(for: .gemini)
    }

    public func resolveAntigravityAuth() async throws -> CodexCLIProxyResolvedAuth {
        try await self.resolveAuth(for: .antigravity)
    }

    public func listAntigravityAuths() async throws -> [CodexCLIProxyResolvedAuth] {
        try await self.listAuths(for: .antigravity)
    }

    public func fetchGeminiQuota(auth: CodexCLIProxyResolvedAuth) async throws -> CLIProxyGeminiQuotaResponse {
        try await self.fetchGeminiLikeQuota(auth: auth)
    }

    public func fetchAntigravityQuota(auth: CodexCLIProxyResolvedAuth) async throws -> CLIProxyGeminiQuotaResponse {
        try await self.fetchGeminiLikeQuota(auth: auth)
    }

    public func fetchCodexUsage(auth: CodexCLIProxyResolvedAuth) async throws -> CodexUsageResponse {
        let usageURL = "https://chatgpt.com/backend-api/wham/usage"
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "User-Agent": "CodexBar",
        ]
        if let accountID = auth.chatGPTAccountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let body = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: usageURL,
            header: headers,
            data: nil)
        let callResponse = try await self.post(path: "/api-call", body: body)

        let statusCode = callResponse.statusCode
        guard (200...299).contains(statusCode) else {
            throw CodexCLIProxyError.apiCallFailed(statusCode, callResponse.compactBody)
        }

        guard let bodyString = callResponse.body else {
            throw CodexCLIProxyError.invalidResponse
        }
        let payload = Data(bodyString.utf8)
        do {
            return try JSONDecoder().decode(CodexUsageResponse.self, from: payload)
        } catch {
            throw CodexCLIProxyError.decodeFailed(error.localizedDescription)
        }
    }

    private func resolveAuth(for provider: CLIProxyAuthProvider) async throws -> CodexCLIProxyResolvedAuth {
        let auths = try await self.listAuths(for: provider)

        if let preferred = self.settings.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty
        {
            guard let selected = auths.first(where: { $0.authIndex == preferred }) else {
                throw provider.missingAuthError(authIndex: preferred)
            }
            return selected
        }

        guard let selected = auths.first else {
            throw provider.missingAuthError(authIndex: nil)
        }
        return selected
    }

    private func listAuths(for provider: CLIProxyAuthProvider) async throws -> [CodexCLIProxyResolvedAuth] {
        let response = try await self.fetchAuthFiles()
        let auths = response.files.filter { provider.matches(provider: $0.provider, type: $0.type) }

        let enabledAuths = auths.filter { !($0.disabled ?? false) }
        let pool = enabledAuths.isEmpty ? auths : enabledAuths
        let mapped = pool.compactMap { auth -> CodexCLIProxyResolvedAuth? in
            let resolved = self.mapResolvedAuth(auth)
            guard !resolved.authIndex.isEmpty else { return nil }
            return resolved
        }
        return mapped.sorted { left, right in
            let l = left.email?.lowercased() ?? left.authIndex.lowercased()
            let r = right.email?.lowercased() ?? right.authIndex.lowercased()
            return l < r
        }
    }

    private func fetchGeminiLikeQuota(auth: CodexCLIProxyResolvedAuth) async throws -> CLIProxyGeminiQuotaResponse {
        let projectID = await self.resolveGeminiProjectID(auth: auth) ?? Self.geminiFallbackProjectID
        let payload = try await self.fetchGeminiLikeQuota(auth: auth, projectID: projectID)
        if !payload.buckets.isEmpty { return payload }
        if projectID != Self.geminiFallbackProjectID {
            return try await self.fetchGeminiLikeQuota(auth: auth, projectID: Self.geminiFallbackProjectID)
        }
        return payload
    }

    private func fetchGeminiLikeQuota(
        auth: CodexCLIProxyResolvedAuth,
        projectID: String) async throws -> CLIProxyGeminiQuotaResponse
    {
        let bodyPayload = GeminiQuotaRequestPayload(project: projectID)
        let requestData = try JSONEncoder().encode(bodyPayload)
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            throw CodexCLIProxyError.invalidResponse
        }

        let body = APICallRequest(
            authIndex: auth.authIndex,
            method: "POST",
            url: Self.geminiQuotaURL,
            header: Self.geminiHeaders,
            data: requestString)
        let callResponse = try await self.post(path: "/api-call", body: body)
        let statusCode = callResponse.statusCode
        guard (200...299).contains(statusCode) else {
            throw CodexCLIProxyError.apiCallFailed(statusCode, callResponse.compactBody)
        }
        guard let bodyString = callResponse.body else {
            throw CodexCLIProxyError.invalidResponse
        }

        let responseData = Data(bodyString.utf8)
        do {
            let decoded = try JSONDecoder().decode(GeminiQuotaResponsePayload.self, from: responseData)
            let buckets = decoded.buckets.compactMap { bucket -> CLIProxyGeminiQuotaBucket? in
                guard let modelID = bucket.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !modelID.isEmpty,
                      let remainingFraction = bucket.remainingFraction
                else {
                    return nil
                }
                return CLIProxyGeminiQuotaBucket(
                    modelID: modelID,
                    remainingFraction: remainingFraction,
                    resetTime: self.parseGeminiResetDate(bucket.resetTime))
            }
            return CLIProxyGeminiQuotaResponse(buckets: buckets)
        } catch {
            throw CodexCLIProxyError.decodeFailed(error.localizedDescription)
        }
    }

    private func resolveGeminiProjectID(auth: CodexCLIProxyResolvedAuth) async -> String? {
        let body = APICallRequest(
            authIndex: auth.authIndex,
            method: "POST",
            url: Self.geminiLoadCodeAssistURL,
            header: Self.geminiHeaders,
            data: "{}")

        guard let response = try? await self.post(path: "/api-call", body: body),
              (200 ... 299).contains(response.statusCode),
              let bodyString = response.body,
              let data = bodyString.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let project = raw["cloudaicompanionProject"] as? String {
            let normalized = project.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        if let project = raw["cloudaicompanionProject"] as? [String: Any] {
            if let id = project["id"] as? String {
                let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { return normalized }
            }
            if let projectID = project["projectId"] as? String {
                let normalized = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { return normalized }
            }
        }

        return nil
    }

    private func parseGeminiResetDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func fetchAuthFiles() async throws -> AuthFilesResponse {
        let (data, statusCode) = try await self.get(path: "/auth-files")
        guard (200...299).contains(statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw CodexCLIProxyError.managementRequestFailed(statusCode, message)
        }
        do {
            return try JSONDecoder().decode(AuthFilesResponse.self, from: data)
        } catch {
            throw CodexCLIProxyError.decodeFailed(error.localizedDescription)
        }
    }

    private func get(path: String) async throws -> (Data, Int) {
        let request = try self.makeRequest(path: path, method: "GET", body: nil)
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexCLIProxyError.invalidResponse
        }
        return (data, http.statusCode)
    }

    private func post<T: Encodable>(path: String, body: T) async throws -> APICallResponse {
        let requestBody = try JSONEncoder().encode(body)
        let request = try self.makeRequest(path: path, method: "POST", body: requestBody)
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexCLIProxyError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw CodexCLIProxyError.managementRequestFailed(http.statusCode, message)
        }
        do {
            return try JSONDecoder().decode(APICallResponse.self, from: data)
        } catch {
            throw CodexCLIProxyError.decodeFailed(error.localizedDescription)
        }
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let base = self.managementURL(path: path) else {
            throw CodexCLIProxyError.invalidBaseURL
        }
        var request = URLRequest(url: base)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(self.settings.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func managementURL(path: String) -> URL? {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let resolvedBaseURL = self.resolvedManagementBaseURL()
        return resolvedBaseURL?.appendingPathComponent(trimmedPath)
    }

    private func resolvedManagementBaseURL() -> URL? {
        let base = self.settings.baseURL
        var normalized = base
        let path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.lowercased().hasSuffix("v0/management") {
            return normalized
        }
        normalized.appendPathComponent("v0", isDirectory: false)
        normalized.appendPathComponent("management", isDirectory: false)
        return normalized
    }

    private func mapResolvedAuth(_ auth: AuthFileEntry) -> CodexCLIProxyResolvedAuth {
        let authIndex = auth.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CodexCLIProxyResolvedAuth(
            authIndex: authIndex,
            email: auth.email,
            chatGPTAccountID: auth.idToken?.chatGPTAccountID,
            planType: auth.idToken?.planType)
    }
}

private struct AuthFilesResponse: Decodable {
    let files: [AuthFileEntry]
}

private struct AuthFileEntry: Decodable {
    let authIndex: String?
    let type: String?
    let provider: String?
    let email: String?
    let disabled: Bool?
    let idToken: IDTokenClaims?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case type
        case provider
        case email
        case disabled
        case idToken = "id_token"
    }
}

private struct IDTokenClaims: Decodable {
    let chatGPTAccountID: String?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case chatGPTAccountID = "chatgpt_account_id"
        case planType = "plan_type"
    }
}

private struct APICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

private struct APICallResponse: Decodable {
    let statusCode: Int
    let header: [String: [String]]?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case header
        case body
    }

    var compactBody: String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 320 ? String(trimmed.prefix(320)) + "…" : trimmed
    }
}

private struct GeminiQuotaRequestPayload: Encodable {
    let project: String
}

private struct GeminiQuotaResponsePayload: Decodable {
    let buckets: [GeminiQuotaBucketPayload]
}

private struct GeminiQuotaBucketPayload: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let modelID: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case remainingFraction
        case resetTime
        case modelID = "modelId"
        case tokenType
    }
}
