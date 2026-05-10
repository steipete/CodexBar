import Foundation
import SweetCookieKit

// swiftformat:disable sortDeclarations
public enum UsageProvider: String, CaseIterable, Sendable, Codable {
    case codex
    case claude
    case cursor
    case opencode
    case opencodego
    case alibaba
    case factory
    case gemini
    case antigravity
    case copilot
    case zai
    case minimax
    case kimi
    case kilo
    case kiro
    case vertexai
    case augment
    case jetbrains
    case kimik2
    case amp
    case ollama
    case synthetic
    case warp
    case openrouter
    case windsurf
    case perplexity
    case abacus
    case mistral
    case deepseek
    case codebuff
    case crof
    case venice
    case commandcode
    case stepfun
}

// swiftformat:enable sortDeclarations

public enum IconStyle: Sendable, CaseIterable {
    case codex
    case claude
    case zai
    case minimax
    case gemini
    case antigravity
    case cursor
    case opencode
    case opencodego
    case alibaba
    case factory
    case copilot
    case kimi
    case kimik2
    case kilo
    case kiro
    case vertexai
    case augment
    case jetbrains
    case amp
    case ollama
    case synthetic
    case warp
    case openrouter
    case windsurf
    case perplexity
    case abacus
    case mistral
    case deepseek
    case codebuff
    case crof
    case venice
    case commandcode
    case stepfun
    case combined
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
    public let isPrimaryProvider: Bool
    public let usesAccountFallback: Bool
    public let browserCookieOrder: BrowserCookieImportOrder?
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
        isPrimaryProvider: Bool = false,
        usesAccountFallback: Bool = false,
        browserCookieOrder: BrowserCookieImportOrder? = nil,
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
        self.isPrimaryProvider = isPrimaryProvider
        self.usesAccountFallback = usesAccountFallback
        self.browserCookieOrder = browserCookieOrder
        self.dashboardURL = dashboardURL
        self.subscriptionDashboardURL = subscriptionDashboardURL
        self.statusPageURL = statusPageURL
        self.statusLinkURL = statusLinkURL
        self.statusWorkspaceProductID = statusWorkspaceProductID
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

    /// Safari first for Cursor: active sessions often live only there, and Chromium profiles may carry stale tokens.
    public static var cursorCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.safari] + Browser.defaultImportOrder.filter { $0 != .safari }
        #else
        nil
        #endif
    }

    /// Preserve the legacy Codex prompt behavior: prefer Safari/Chrome/Firefox before
    /// probing additional Chromium variants that may trigger Safe Storage prompts.
    public static var codexCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        let preferredPrefix: [Browser] = [.safari, .chrome, .firefox]
        return preferredPrefix + Browser.defaultImportOrder.filter { !preferredPrefix.contains($0) }
        #else
        nil
        #endif
    }
}
