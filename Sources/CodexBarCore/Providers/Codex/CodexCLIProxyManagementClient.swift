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

public struct CodexCLIProxyManagementClient: Sendable {
    private let settings: CodexCLIProxySettings
    private let session: URLSession

    public init(settings: CodexCLIProxySettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public func resolveCodexAuth() async throws -> CodexCLIProxyResolvedAuth {
        let auths = try await self.listCodexAuths()

        if let preferred = self.settings.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty
        {
            guard let selected = auths.first(where: { $0.authIndex == preferred }) else {
                throw CodexCLIProxyError.missingCodexAuth(preferred)
            }
            return selected
        }

        guard let selected = auths.first else {
            throw CodexCLIProxyError.missingCodexAuth(nil)
        }
        return selected
    }

    public func listCodexAuths() async throws -> [CodexCLIProxyResolvedAuth] {
        let response = try await self.fetchAuthFiles()
        let auths = response.files.filter { file in
            let provider = file.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let type = file.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return provider == "codex" || type == "codex"
        }

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
