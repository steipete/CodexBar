import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexBankedResetsFetcher {
    private static let bankedResetsPath = "/wham/rate-limit-reset-credits"

    public static func fetchBankedResets(
        accessToken: String,
        accountId: String?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        configContents: String? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> CodexBankedResetsSnapshot
    {
        var request = URLRequest(url: Self.resolveBankedResetsURL(env: env, configContents: configContents))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let response = try await transport.response(for: request)
            let data = response.data

            switch response.statusCode {
            case 200...299:
                do {
                    let endpointResponse = try CodexBankedResetsResponse.decodeEndpointPayload(data)
                    return endpointResponse.snapshot(updatedAt: now)
                } catch {
                    throw CodexOAuthFetchError.invalidResponse
                }
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                let body = String(data: data, encoding: .utf8)
                throw CodexOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch {
            throw CodexOAuthFetchError.networkError(error)
        }
    }

    private static func resolveBankedResetsURL(env: [String: String], configContents: String?) -> URL {
        let normalized = CodexChatGPTBaseURLResolver.resolveNormalizedBaseURL(
            env: env,
            configContents: configContents,
            backendAPIResolution: .always)
        let full = normalized + Self.bankedResetsPath
        return URL(string: full) ?? URL(
            string: CodexChatGPTBaseURLResolver.defaultBackendAPIBaseURL + Self.bankedResetsPath)!
    }
}

#if DEBUG
extension CodexBankedResetsFetcher {
    static func _resolveBankedResetsURLForTesting(env: [String: String] = [:], configContents: String? = nil) -> URL {
        self.resolveBankedResetsURL(env: env, configContents: configContents)
    }
}
#endif
