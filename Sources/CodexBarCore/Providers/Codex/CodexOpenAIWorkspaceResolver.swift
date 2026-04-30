import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexOpenAIWorkspaceIdentity: Equatable, Sendable {
    public let workspaceAccountID: String
    public let workspaceLabel: String?

    public init(workspaceAccountID: String, workspaceLabel: String?) {
        self.workspaceAccountID = Self.normalizeWorkspaceAccountID(workspaceAccountID)
        self.workspaceLabel = Self.normalizeWorkspaceLabel(workspaceLabel)
    }

    public static func normalizeWorkspaceAccountID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizeWorkspaceLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum CodexOpenAIWorkspaceResolver {
    private struct AccountsResponse: Decodable {
        let items: [AccountItem]
    }

    private struct AccountItem: Decodable {
        let id: String
        let name: String?
    }

    private static let accountsURL = URL(string: "https://chatgpt.com/backend-api/accounts")!

    public static func resolve(
        credentials: CodexOAuthCredentials,
        session: URLSession = .shared) async throws -> CodexOpenAIWorkspaceIdentity?
    {
        guard let workspaceAccountID = normalizeWorkspaceAccountID(credentials.accountId) else {
            return nil
        }

        let identities = try await self.listWorkspaces(credentials: credentials, session: session)
        if let identity = identities.first(where: { $0.workspaceAccountID == workspaceAccountID }) {
            return identity
        }

        return CodexOpenAIWorkspaceIdentity(
            workspaceAccountID: workspaceAccountID,
            workspaceLabel: nil)
    }

    public static func listWorkspaces(
        credentials: CodexOAuthCredentials,
        session: URLSession = .shared) async throws -> [CodexOpenAIWorkspaceIdentity]
    {
        var request = URLRequest(url: self.accountsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let workspaceAccountID = normalizeWorkspaceAccountID(credentials.accountId) {
            request.setValue(workspaceAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw CodexOpenAIWorkspaceResolverError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AccountsResponse.self, from: data)
        return decoded.items.compactMap { account in
            guard let workspaceAccountID = self.normalizeWorkspaceAccountID(account.id) else { return nil }
            return CodexOpenAIWorkspaceIdentity(
                workspaceAccountID: workspaceAccountID,
                workspaceLabel: self.resolveWorkspaceLabel(from: account))
        }
    }

    public static func normalizeWorkspaceAccountID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func resolveWorkspaceLabel(from account: AccountItem) -> String? {
        let name = account.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        return "Personal"
    }
}

public enum CodexOpenAIWorkspaceResolverError: LocalizedError, Sendable {
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI account lookup returned an invalid response."
        }
    }
}
