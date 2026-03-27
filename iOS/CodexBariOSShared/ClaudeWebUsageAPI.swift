import Foundation

public enum ClaudeWebUsageAPIError: LocalizedError, Sendable {
    case missingSessionKey
    case unauthorized
    case invalidResponse
    case noOrganization
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .missingSessionKey:
            return "Claude web session is missing."
        case .unauthorized:
            return "Claude web session is invalid or expired."
        case .invalidResponse:
            return "Claude web usage API returned an invalid response."
        case .noOrganization:
            return "Claude did not return a usable organization for this account."
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                return "Claude web usage API error \(code): \(body)"
            }
            return "Claude web usage API error \(code)."
        case let .networkError(error):
            return "Claude web network error: \(error.localizedDescription)"
        }
    }
}

public enum ClaudeWebUsageAPI {
    private static let baseURL = "https://claude.ai/api"

    public static func fetchUsage(sessionKey: String) async throws -> ClaudeOAuthUsageResponse {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else {
            throw ClaudeWebUsageAPIError.missingSessionKey
        }

        let organization = try await self.fetchOrganization(sessionKey: normalizedSessionKey)
        return try await self.fetchUsage(orgID: organization.id, sessionKey: normalizedSessionKey)
    }

    public static func makeEntry(
        response: ClaudeOAuthUsageResponse,
        updatedAt: Date = Date()) throws -> WidgetSnapshot.ProviderEntry
    {
        try ClaudeUsageAPI.makeEntry(response: response, updatedAt: updatedAt)
    }

    private static func fetchOrganization(sessionKey: String) async throws -> OrganizationInfo {
        let request = self.request(path: "/organizations", sessionKey: sessionKey)
        let data = try await self.send(request)
        return try self.selectOrganization(from: data)
    }

    private static func fetchUsage(orgID: String, sessionKey: String) async throws -> ClaudeOAuthUsageResponse {
        let request = self.request(path: "/organizations/\(orgID)/usage", sessionKey: sessionKey)
        let data = try await self.send(request)

        do {
            return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
        } catch {
            throw ClaudeWebUsageAPIError.invalidResponse
        }
    }

    private static func request(path: String, sessionKey: String) -> URLRequest {
        let url = URL(string: self.baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("claude-web/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeWebUsageAPIError.invalidResponse
            }

            switch http.statusCode {
            case 200:
                return data
            case 401, 403:
                throw ClaudeWebUsageAPIError.unauthorized
            default:
                throw ClaudeWebUsageAPIError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
        } catch let error as ClaudeWebUsageAPIError {
            throw error
        } catch {
            throw ClaudeWebUsageAPIError.networkError(error)
        }
    }

    private static func selectOrganization(from data: Data) throws -> OrganizationInfo {
        let organizations: [OrganizationResponse]

        do {
            organizations = try JSONDecoder().decode([OrganizationResponse].self, from: data)
        } catch {
            throw ClaudeWebUsageAPIError.invalidResponse
        }

        guard let selected = organizations.first(where: \.hasChatCapability)
            ?? organizations.first(where: { !$0.isAPIOnly })
            ?? organizations.first
        else {
            throw ClaudeWebUsageAPIError.noOrganization
        }

        return OrganizationInfo(id: selected.uuid)
    }

    private struct OrganizationInfo: Sendable {
        let id: String
    }

    private struct OrganizationResponse: Decodable {
        let uuid: String
        let capabilities: [String]?

        var hasChatCapability: Bool {
            self.normalizedCapabilities.contains("chat")
        }

        var isAPIOnly: Bool {
            let normalizedCapabilities = self.normalizedCapabilities
            return !normalizedCapabilities.isEmpty && normalizedCapabilities == ["api"]
        }

        private var normalizedCapabilities: [String] {
            (self.capabilities ?? []).map { $0.lowercased() }
        }
    }

    #if DEBUG
    public static func _selectOrganizationIDForTesting(from data: Data) throws -> String {
        try self.selectOrganization(from: data).id
    }
    #endif
}
