import Foundation
import SweetCookieKit

public struct ProviderDebugPaneCapabilities: Sendable {
    public let probeLogOrder: Int?
    public let notificationSimulationOrder: Int?
    public let errorSimulationOrder: Int?

    public init(
        probeLogOrder: Int? = nil,
        notificationSimulationOrder: Int? = nil,
        errorSimulationOrder: Int? = nil)
    {
        self.probeLogOrder = probeLogOrder
        self.notificationSimulationOrder = notificationSimulationOrder
        self.errorSimulationOrder = errorSimulationOrder
    }
}

// swiftformat:disable sortDeclarations
public enum UsageProvider: String, CaseIterable, Sendable, Codable {
    case codex
    case openai
    case azureopenai
    case claude
    case clinepass
    case cursor
    case opencode
    case opencodego
    case alibaba
    case alibabatokenplan
    case qwencloud
    case factory
    case fireworks
    case gemini
    case antigravity
    case copilot
    case devin
    case zai
    case minimax
    case manus
    case kimi
    case kilo
    case kiro
    case vertexai
    case augment
    case jetbrains
    case moonshot
    case amp
    case t3chat
    case ollama
    case synthetic
    case openrouter
    case elevenlabs
    case warp
    case windsurf
    case zed
    case perplexity
    case mimo
    case doubao
    case sakana
    case abacus
    case mistral
    case deepseek
    case deepinfra
    case codebuff
    case crof
    case venice
    case commandcode
    case qoder
    case stepfun
    case bedrock
    case grok
    case groq
    case llmproxy
    case litellm
    case deepgram
    case poe
    case chutes
    case neuralwatt
    case clawrouter
    case longcat
    case sub2api
    case wayfinder
    case zenmux
    case aiand
    case zoommate
    case xai
    case notion
    case ibmbob
}

// swiftformat:enable sortDeclarations

public struct IconStyle: RawRepresentable, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    public let rawValue: String

    public var description: String {
        self.rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(provider: UsageProvider) {
        self.init(rawValue: provider.rawValue)
    }

    public static var allCases: [IconStyle] {
        UsageProvider.allCases.map(Self.init(provider:)) + [.combined]
    }

    // Provider-specific by design: named styles preserve source-compatible renderer entry points.
    public static let codex = Self(provider: .codex)
    public static let claude = Self(provider: .claude)
    public static let gemini = Self(provider: .gemini)
    public static let antigravity = Self(provider: .antigravity)
    public static let cursor = Self(provider: .cursor)
    public static let factory = Self(provider: .factory)
    public static let copilot = Self(provider: .copilot)
    public static let commandcode = Self(provider: .commandcode)
    public static let kimi = Self(provider: .kimi)
    public static let mimo = Self(provider: .mimo)
    public static let mistral = Self(provider: .mistral)
    public static let qoder = Self(provider: .qoder)
    public static let warp = Self(provider: .warp)
    public static let perplexity = Self(provider: .perplexity)
    public static let combined = Self(rawValue: "combined")
}

public struct ProviderMetadata: Sendable {
    public let id: UsageProvider
    public let displayName: String
    public let shortDisplayName: String
    public let sessionLabel: String
    public let weeklyLabel: String
    public let opusLabel: String?
    public let supportsOpus: Bool
    public let supportsCredits: Bool
    public let creditsHint: String
    public let toggleTitle: String
    public let cliName: String
    public let defaultEnabled: Bool
    public let widgetSelectable: Bool
    public let isPrimaryProvider: Bool
    public let usesAccountFallback: Bool
    public let sharePlanLabels: [String: String]
    public let debugLogUnavailableMessage: String?
    public let debugPane: ProviderDebugPaneCapabilities
    public let balanceOnly: Bool
    public let usesDetailBackedWindow: Bool
    public let browserCookieOrder: BrowserCookieImportOrder?
    public let dashboardURL: String?
    public let subscriptionDashboardURL: String?
    /// Provider-specific release notes or changelog URL for CLI/provider updates.
    public let changelogURL: String?
    /// Statuspage.io base URL for incident polling (append /api/v2/status.json).
    public let statusPageURL: String?
    /// Browser-only status link (no API polling); used when statusPageURL is nil.
    public let statusLinkURL: String?
    /// Google Workspace product ID for status polling (appsstatus dashboard).
    public let statusWorkspaceProductID: String?
    /// Optional top-level component/group names to show from a provider status feed.
    public let statusComponentAllowlist: Set<String>?

    public init(
        id: UsageProvider,
        displayName: String,
        shortDisplayName: String? = nil,
        sessionLabel: String,
        weeklyLabel: String,
        opusLabel: String?,
        supportsOpus: Bool,
        supportsCredits: Bool,
        creditsHint: String,
        toggleTitle: String,
        cliName: String,
        defaultEnabled: Bool,
        widgetSelectable: Bool = true,
        isPrimaryProvider: Bool = false,
        usesAccountFallback: Bool = false,
        sharePlanLabels: [String: String] = [:],
        debugLogUnavailableMessage: String? = nil,
        debugPane: ProviderDebugPaneCapabilities = .init(),
        balanceOnly: Bool = false,
        usesDetailBackedWindow: Bool = false,
        browserCookieOrder: BrowserCookieImportOrder? = nil,
        dashboardURL: String?,
        subscriptionDashboardURL: String? = nil,
        changelogURL: String? = nil,
        statusPageURL: String?,
        statusLinkURL: String? = nil,
        statusWorkspaceProductID: String? = nil,
        statusComponentAllowlist: Set<String>? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.shortDisplayName = shortDisplayName ?? displayName
        self.sessionLabel = sessionLabel
        self.weeklyLabel = weeklyLabel
        self.opusLabel = opusLabel
        self.supportsOpus = supportsOpus
        self.supportsCredits = supportsCredits
        self.creditsHint = creditsHint
        self.toggleTitle = toggleTitle
        self.cliName = cliName
        self.defaultEnabled = defaultEnabled
        self.widgetSelectable = widgetSelectable
        self.isPrimaryProvider = isPrimaryProvider
        self.usesAccountFallback = usesAccountFallback
        self.sharePlanLabels = sharePlanLabels
        self.debugLogUnavailableMessage = debugLogUnavailableMessage
        self.debugPane = debugPane
        self.balanceOnly = balanceOnly
        self.usesDetailBackedWindow = usesDetailBackedWindow
        self.browserCookieOrder = browserCookieOrder
        self.dashboardURL = dashboardURL
        self.subscriptionDashboardURL = subscriptionDashboardURL
        self.changelogURL = changelogURL
        self.statusPageURL = statusPageURL
        self.statusLinkURL = statusLinkURL
        self.statusWorkspaceProductID = statusWorkspaceProductID
        self.statusComponentAllowlist = statusComponentAllowlist
    }
}

public enum ProviderDefaults {
    public static var metadata: [UsageProvider: ProviderMetadata] {
        ProviderDescriptorRegistry.metadata
    }
}

public enum ProviderBrowserCookieDefaults {
    public static var defaultImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        Browser.defaultImportOrder
        #else
        nil
        #endif
    }
}
