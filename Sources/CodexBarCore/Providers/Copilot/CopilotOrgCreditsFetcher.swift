import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads organization-wide AI credit consumption from GitHub's billing API.
///
/// Best-effort by design: the Copilot device flow requests only `read:user`, so this call may well be
/// rejected. Every failure path returns `nil` so the rest of the Copilot card is unaffected.
public struct CopilotOrgCreditsFetcher: Sendable {
    struct UsageReport: Decodable {
        struct Item: Decodable {
            let grossQuantity: Double?
        }

        let usageItems: [Item]
    }

    private let token: String
    private let enterpriseHost: String?
    private let transport: any ProviderHTTPTransport

    public init(
        token: String,
        enterpriseHost: String? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.token = token
        self.enterpriseHost = enterpriseHost
        self.transport = transport
    }

    public static func usageURL(org: String, enterpriseHost: String?) -> URL? {
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !encoded.isEmpty
        else { return nil }
        return CopilotDeviceFlow.makeRequestURL(
            host: CopilotUsageFetcher.apiHost(enterpriseHost: enterpriseHost),
            path: "/orgs/\(encoded)/settings/billing/ai_credit/usage")
    }

    /// Total AI credits consumed by the organization this billing period, or `nil` when unavailable.
    public func fetchCreditsUsed(org: String) async -> Double? {
        guard let url = Self.usageURL(org: org, enterpriseHost: self.enterpriseHost) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("token \(self.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        guard let response = try? await self.transport.response(for: request),
              response.statusCode == 200,
              let report = try? JSONDecoder().decode(UsageReport.self, from: response.data)
        else { return nil }

        return report.usageItems.reduce(0) { $0 + ($1.grossQuantity ?? 0) }
    }
}
