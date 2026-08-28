import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexPATWhoami: Equatable, Sendable {
    public let accountId: String?
    public let email: String?
    public let planType: String?
}

public struct CodexPATUsageFetch: Sendable {
    public let usage: CodexUsageResponse
    public let whoami: CodexPATWhoami?
}

enum CodexPATUsageFetcher {
    private static let whoamiURL = URL(
        string: "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami")!

    static func fetchUsage(
        credentials: CodexPATCredentials,
        cliVersion: String?,
        env: [String: String] = ProcessInfo.processInfo.environment) async throws -> CodexPATUsageFetch
    {
        try await self.fetchUsage(
            credentials: credentials,
            cliVersion: cliVersion,
            env: env,
            session: CodexAuthenticatedHTTPTransport.current)
    }

    static func fetchUsage(
        credentials: CodexPATCredentials,
        cliVersion: String?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        session transport: any ProviderHTTPTransport) async throws -> CodexPATUsageFetch
    {
        let userAgent = CodexCLIUserAgent.make(cliVersion: cliVersion)
        let whoami = try await self.fetchWhoami(
            token: credentials.token,
            userAgent: userAgent,
            session: transport)
        // PAT identity comes from the token's whoami payload. A stale managed-workspace
        // ChatGPT-Account-Id would query the wrong account after CODEX_HOME fail-closes.
        let usage = try await self.fetchUsage(
            token: credentials.token,
            accountId: Self.firstNonEmpty(whoami.accountId),
            userAgent: userAgent,
            env: env,
            session: transport)
        return CodexPATUsageFetch(usage: usage, whoami: whoami)
    }

    private static func fetchWhoami(
        token: String,
        userAgent: String,
        session transport: any ProviderHTTPTransport) async throws -> CodexPATWhoami
    {
        var request = URLRequest(
            url: Self.whoamiURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpMethod = "GET"
        Self.applyPATHeaders(to: &request, token: token, userAgent: userAgent)

        let data = try await self.perform(request: request, session: transport)
        do {
            return try JSONDecoder().decode(WhoamiResponse.self, from: data).model
        } catch {
            throw CodexOAuthFetchError.invalidResponse
        }
    }

    private static func fetchUsage(
        token: String,
        accountId: String?,
        userAgent: String,
        env: [String: String],
        session transport: any ProviderHTTPTransport) async throws -> CodexUsageResponse
    {
        var request = URLRequest(
            url: CodexOAuthUsageFetcher.chatGPTUsageURL(env: env),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpMethod = "GET"
        Self.applyPATHeaders(to: &request, token: token, userAgent: userAgent)
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data = try await self.perform(request: request, session: transport)
        do {
            return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw CodexOAuthFetchError.invalidResponse
        }
    }

    private static func applyPATHeaders(
        to request: inout URLRequest, token: String, userAgent: String)
    {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CodexCLIUserAgent.originator, forHTTPHeaderField: "originator")
    }

    private static func perform(
        request: URLRequest,
        session transport: any ProviderHTTPTransport) async throws -> Data
    {
        do {
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200...299:
                return response.data
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                let body = String(data: response.data, encoding: .utf8)
                throw CodexOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw CodexOAuthFetchError.networkError(error)
        }
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private struct WhoamiResponse: Decodable {
        let chatgptAccountId: String?
        let chatgptPlanType: String?
        let email: String?

        private enum CodingKeys: String, CodingKey {
            case chatgptAccountId = "chatgpt_account_id"
            case chatgptPlanType = "chatgpt_plan_type"
            case email
        }

        var model: CodexPATWhoami {
            CodexPATWhoami(
                accountId: Self.nonEmpty(self.chatgptAccountId),
                email: Self.nonEmpty(self.email),
                planType: Self.nonEmpty(self.chatgptPlanType))
        }

        private static func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }
}

#if DEBUG
extension CodexPATUsageFetcher {
    static func _userAgentForTesting(cliVersion: String?) -> String {
        CodexCLIUserAgent.make(cliVersion: cliVersion)
    }

    static func _normalizedCLIVersionForTesting(_ versionString: String?) -> String? {
        CodexCLIUserAgent.normalizedCLIVersion(versionString)
    }
}
#endif
