import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProviderPayload: Encodable {
    let provider: String
    let account: String?
    let cacheAccountKey: String?
    let version: String?
    let source: String
    let status: ProviderStatusPayload?
    let usage: UsageSnapshot?
    let credits: CreditsSnapshot?
    let antigravityPlanInfo: AntigravityPlanInfoSummary?
    let openaiDashboard: OpenAIDashboardSnapshot?
    let diagnostic: String?
    let error: ProviderErrorPayload?
    let pace: ProviderPacePayload?

    private enum CodingKeys: String, CodingKey {
        case provider
        case account
        case version
        case source
        case status
        case usage
        case credits
        case antigravityPlanInfo
        case openaiDashboard
        case diagnostic
        case error
        case pace
    }

    init(
        provider: UsageProvider,
        account: String?,
        cacheAccountKey: String? = nil,
        version: String?,
        source: String,
        status: ProviderStatusPayload?,
        usage: UsageSnapshot?,
        credits: CreditsSnapshot?,
        antigravityPlanInfo: AntigravityPlanInfoSummary?,
        openaiDashboard: OpenAIDashboardSnapshot?,
        error: ProviderErrorPayload?,
        diagnostic: String? = nil,
        pace: ProviderPacePayload? = nil)
    {
        self.provider = provider.rawValue
        self.account = account
        self.cacheAccountKey = cacheAccountKey
        self.version = version
        self.source = source
        self.status = status
        self.usage = usage
        self.credits = credits
        self.antigravityPlanInfo = antigravityPlanInfo
        self.openaiDashboard = openaiDashboard
        self.diagnostic = diagnostic
        self.error = error
        self.pace = pace
    }

    init(
        providerID: String,
        account: String?,
        cacheAccountKey: String? = nil,
        version: String?,
        source: String,
        status: ProviderStatusPayload?,
        usage: UsageSnapshot?,
        credits: CreditsSnapshot?,
        antigravityPlanInfo: AntigravityPlanInfoSummary?,
        openaiDashboard: OpenAIDashboardSnapshot?,
        error: ProviderErrorPayload?,
        diagnostic: String? = nil,
        pace: ProviderPacePayload? = nil)
    {
        self.provider = providerID
        self.account = account
        self.cacheAccountKey = cacheAccountKey
        self.version = version
        self.source = source
        self.status = status
        self.usage = usage
        self.credits = credits
        self.antigravityPlanInfo = antigravityPlanInfo
        self.openaiDashboard = openaiDashboard
        self.diagnostic = diagnostic
        self.error = error
        self.pace = pace
    }
}

struct ProviderPacePayload: Encodable {
    let primary: PacePayload?
    let secondary: PacePayload?
}

struct PacePayload: Encodable {
    let stage: String
    /// Rounded (used − expected); positive = deficit, negative = reserve.
    let deltaPercent: Double
    let expectedUsedPercent: Double
    let willLastToReset: Bool
    let etaSeconds: TimeInterval?
    /// Always absent in CLI output; kept for schema parity.
    let runOutProbability: Double?
    let summary: String
}

struct ProviderStatusPayload: Encodable {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
    let url: String

    enum ProviderStatusIndicator: String, Encodable {
        case none
        case minor
        case major
        case critical
        case maintenance
        case unknown

        var label: String {
            switch self {
            case .none: "Operational"
            case .minor: "Partial outage"
            case .major: "Major outage"
            case .critical: "Critical issue"
            case .maintenance: "Maintenance"
            case .unknown: "Status unknown"
            }
        }
    }

    var descriptionSuffix: String {
        guard let description, !description.isEmpty else { return "" }
        return " – \(description)"
    }
}

enum StatusFetcher {
    static func fetch(from baseURL: URL) async throws -> ProviderStatusPayload {
        let apiURL = baseURL.appendingPathComponent("api/v2/status.json")
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }

            struct Page: Decodable {
                let updatedAt: Date?

                private enum CodingKeys: String, CodingKey {
                    case updatedAt = "updated_at"
                }
            }

            let page: Page?
            let status: Status
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }

        let response = try decoder.decode(Response.self, from: data)
        let indicator = ProviderStatusPayload.ProviderStatusIndicator(rawValue: response.status.indicator) ?? .unknown
        return ProviderStatusPayload(
            indicator: indicator,
            description: response.status.description,
            updatedAt: response.page?.updatedAt,
            url: baseURL.absoluteString)
    }
}
