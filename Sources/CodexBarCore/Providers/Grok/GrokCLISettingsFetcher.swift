import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the Grok CLI settings envelope. Plan names live here (`subscription_tier_display`),
/// not on `/v1/billing?format=credits`.
enum GrokCLISettingsFetcher {
    static let defaultEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    static let requestTimeoutSeconds: TimeInterval = 2

    static func endpoint(fromBilling billing: URL) -> URL {
        var components = URLComponents(url: billing, resolvingAgainstBaseURL: false)
        components?.path = "/v1/settings"
        components?.query = nil
        return components?.url ?? self.defaultEndpoint
    }

    static func subscriptionTierDisplay(
        credentials: GrokCredentials,
        session transport: any ProviderHTTPTransport,
        endpoint: URL = Self.defaultEndpoint) async throws -> String?
    {
        guard !credentials.isExpired else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            return nil
        }
        guard response.statusCode == 200 else { return nil }
        return self.parse(response.data)
    }

    static func parse(_ data: Data) -> String? {
        struct SettingsResponse: Decodable {
            let subscriptionTierDisplay: String?

            enum CodingKeys: String, CodingKey {
                case subscriptionTierDisplay = "subscription_tier_display"
            }
        }

        guard let response = try? JSONDecoder().decode(SettingsResponse.self, from: data) else {
            return nil
        }
        return GrokPlan.displayName(from: response.subscriptionTierDisplay)
    }
}
