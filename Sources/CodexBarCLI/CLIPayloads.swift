import CodexBarCore
import Foundation

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
        self.init(
            providerID: provider.rawValue,
            account: account,
            cacheAccountKey: cacheAccountKey,
            version: version,
            source: source,
            status: status,
            usage: usage,
            credits: credits,
            antigravityPlanInfo: antigravityPlanInfo,
            openaiDashboard: openaiDashboard,
            error: error,
            diagnostic: diagnostic,
            pace: pace)
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
    let tertiary: PacePayload?
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

    var descriptionSuffix: String {
        guard let description, !description.isEmpty else { return "" }
        return " – \(description)"
    }
}

extension ProviderStatusIndicator {
    var cliLabel: String {
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
