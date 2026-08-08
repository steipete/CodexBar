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
            /// GitHub's docs show `unitType: "credits"` for organization reports and `"ai-credits"`
            /// for user-level reports, and live org responses have been observed with `"ai-credits"`.
            /// Both spellings are summed; an unrelated unit type cannot silently inflate the total.
            let unitType: String?
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
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: orgSegmentAllowedCharacters),
              !encoded.isEmpty
        else { return nil }
        return CopilotDeviceFlow.makeRequestURL(
            host: CopilotUsageFetcher.apiHost(enterpriseHost: enterpriseHost),
            path: "/organizations/\(encoded)/settings/billing/ai_credit/usage")
    }

    /// `.urlPathAllowed` leaves `/` unescaped since it is meant for encoding a full multi-segment
    /// path. `org` is a single path segment, so `/` must be escaped here too, or an org value such
    /// as `"../../repos/x"` would traverse outside `/organizations/<org>/...` on the request host.
    private static let orgSegmentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    /// Unit-type spellings observed for AI-credit line items: `"credits"` per GitHub's organization
    /// report docs, `"ai-credits"` per the user-level docs and live organization responses.
    private static let creditUnitTypes: Set<String> = ["credits", "ai-credits"]

    /// Total AI credits consumed by the organization this billing period, or `nil` when unavailable.
    public func fetchCreditsUsed(org: String) async -> Double? {
        guard let url = Self.usageURL(org: org, enterpriseHost: self.enterpriseHost) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("token \(self.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let response: ProviderHTTPResponse
        do {
            response = try await self.transport.response(for: request)
        } catch {
            // Best-effort by design (see the type doc comment): the common case is a token without
            // org billing access, so this stays a warning rather than surfacing an error on the card.
            CodexBarLog.logger(LogCategories.providers).warning(
                "Copilot org credits unavailable",
                metadata: ["error": "\(error.localizedDescription)"])
            return nil
        }

        guard response.statusCode == 200 else {
            CodexBarLog.logger(LogCategories.providers).warning(
                "Copilot org credits unavailable",
                metadata: ["statusCode": "\(response.statusCode)"])
            return nil
        }

        guard let report = try? JSONDecoder().decode(UsageReport.self, from: response.data) else {
            CodexBarLog.logger(LogCategories.providers).warning(
                "Copilot org credits unavailable",
                metadata: ["error": "could not decode usage report"])
            return nil
        }

        guard !report.usageItems.isEmpty else {
            // A genuinely empty usage list is a successful response reporting no usage this period.
            return 0
        }

        let creditItems = report.usageItems.filter { Self.creditUnitTypes.contains($0.unitType ?? "") }
        guard !creditItems.isEmpty else {
            // Usage items came back, but none matched a known credit unit type -- that is data we
            // could not interpret, not zero usage. If GitHub ever changes the unit-type spelling,
            // returning 0 here would render a fabricated "0 credits used" (or a fabricated 0% bar
            // against a configured entitlement) instead of surfacing the unrecognized response.
            CodexBarLog.logger(LogCategories.providers).warning(
                "Copilot org credits unavailable",
                metadata: ["error": "no usage items matched a credit unitType"])
            return nil
        }

        return creditItems.reduce(0) { $0 + ($1.grossQuantity ?? 0) }
    }
}
