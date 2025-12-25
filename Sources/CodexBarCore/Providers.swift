import Foundation

public enum UsageProvider: String, CaseIterable, Sendable, Codable {
    case codex
    case claude
    case gemini
    case antigravity
    case cursor
}

public struct ProviderMetadata: Sendable {
    public let id: UsageProvider
    public let displayName: String
    public let sessionLabel: String
    public let weeklyLabel: String
    public let opusLabel: String?
    public let supportsOpus: Bool
    public let supportsCredits: Bool
    public let creditsHint: String
    public let toggleTitle: String
    public let cliName: String
    public let defaultEnabled: Bool
    public let dashboardURL: String?
    public let subscriptionDashboardURL: String?
    /// Statuspage.io base URL for incident polling (append /api/v2/status.json).
    public let statusPageURL: String?
    /// Browser-only status link (no API polling); used when statusPageURL is nil.
    public let statusLinkURL: String?
    /// Google Workspace product ID for status polling (appsstatus dashboard).
    public let statusWorkspaceProductID: String?

    public init(
        id: UsageProvider,
        displayName: String,
        sessionLabel: String,
        weeklyLabel: String,
        opusLabel: String?,
        supportsOpus: Bool,
        supportsCredits: Bool,
        creditsHint: String,
        toggleTitle: String,
        cliName: String,
        defaultEnabled: Bool,
        dashboardURL: String?,
        subscriptionDashboardURL: String? = nil,
        statusPageURL: String?,
        statusLinkURL: String? = nil,
        statusWorkspaceProductID: String? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.sessionLabel = sessionLabel
        self.weeklyLabel = weeklyLabel
        self.opusLabel = opusLabel
        self.supportsOpus = supportsOpus
        self.supportsCredits = supportsCredits
        self.creditsHint = creditsHint
        self.toggleTitle = toggleTitle
        self.cliName = cliName
        self.defaultEnabled = defaultEnabled
        self.dashboardURL = dashboardURL
        self.subscriptionDashboardURL = subscriptionDashboardURL
        self.statusPageURL = statusPageURL
        self.statusLinkURL = statusLinkURL
        self.statusWorkspaceProductID = statusWorkspaceProductID
    }
}

public enum ProviderDefaults {
    public static let metadata: [UsageProvider: ProviderMetadata] = [
        .codex: ProviderMetadata(
            id: .codex,
            displayName: "Codex",
            sessionLabel: "Session",
            weeklyLabel: "Weekly",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: true,
            creditsHint: "Credits unavailable; keep Codex running to refresh.",
            toggleTitle: "Show Codex usage",
            cliName: "codex",
            defaultEnabled: true,
            dashboardURL: "https://chatgpt.com/codex/settings/usage",
            statusPageURL: "https://status.openai.com/"),
        .claude: ProviderMetadata(
            id: .claude,
            displayName: "Claude",
            sessionLabel: "Session",
            weeklyLabel: "Weekly",
            opusLabel: "Sonnet",
            supportsOpus: true,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show Claude Code usage",
            cliName: "claude",
            defaultEnabled: false,
            dashboardURL: "https://console.anthropic.com/settings/billing",
            subscriptionDashboardURL: "https://claude.ai/settings/usage",
            statusPageURL: "https://status.claude.com/"),
        .gemini: ProviderMetadata(
            id: .gemini,
            displayName: "Gemini",
            sessionLabel: "Pro",
            weeklyLabel: "Flash",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show Gemini usage",
            cliName: "gemini",
            defaultEnabled: false,
            dashboardURL: "https://gemini.google.com",
            statusPageURL: nil,
            statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo",
            statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
        .antigravity: ProviderMetadata(
            id: .antigravity,
            displayName: "Antigravity",
            sessionLabel: "Claude",
            weeklyLabel: "Gemini Pro",
            opusLabel: "Gemini Flash",
            supportsOpus: true,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show Antigravity usage (experimental)",
            cliName: "antigravity",
            defaultEnabled: false,
            dashboardURL: nil,
            statusPageURL: nil,
            statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo",
            statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
        .cursor: ProviderMetadata(
            id: .cursor,
            displayName: "Cursor",
            sessionLabel: "Plan",
            weeklyLabel: "On-Demand",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: true,
            creditsHint: "On-demand usage beyond included plan limits.",
            toggleTitle: "Show Cursor usage",
            cliName: "cursor",
            defaultEnabled: false,
            dashboardURL: "https://cursor.com/dashboard?tab=usage",
            statusPageURL: nil,
            statusLinkURL: "https://status.cursor.com"),
    ]
}
