import Foundation
import SweetCookieKit

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
    case warp
    case openrouter
    case elevenlabs
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

    // Named styles below carry renderer behavior or preserve source-compatible call sites.
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
    public static var chromeOnlyImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

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

    /// OpenCode web Auto stays Chrome-only by default, with Dia as the one bounded provider exception
    /// because Dia has a confirmed reporter need. Other browsers stay on Manual until users can choose them.
    public static var opencodeCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .dia]
        #else
        nil
        #endif
    }

    /// Grok is normally signed in through Chrome; keep this narrow so CLI/live probes do not touch
    /// unrelated browser keychains.
    public static var grokCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    /// MiMo Auto: Safari first (no Keychain prompt), keep the existing Chrome-family
    /// entries from main, and add Firefox/Edge per #1304. Other Chromium forks stay on
    /// Manual import to avoid scanning the full SweetCookieKit default order.
    public static var mimoCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.safari, .chrome, .chromeBeta, .chromeCanary, .firefox, .edge]
        #else
        nil
        #endif
    }

    /// Devin sessions are normally in Chrome. Keep automatic import narrow so live probes do not
    /// touch unrelated browser keychains; users can select another browser explicitly.
    public static var devinCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    /// Copilot budget imports should stay Chrome-only by default to avoid prompting unrelated browsers.
    public static var copilotCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    /// LongCat Auto keeps Chrome first for existing users, then checks Firefox without adding
    /// an unrelated browser Keychain prompt.
    public static var longcatCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .firefox]
        #else
        nil
        #endif
    }

    /// Qoder sessions are documented through Chrome cookie import. Keep automatic import narrow
    /// so enabling this provider does not probe unrelated browser keychains.
    public static var qoderCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    /// Mistral Auto: Chrome first (matches the original Chrome-only behavior so
    /// existing users see no change), then Firefox so users signed in via Firefox
    /// or Firefox Developer Edition are detected without Manual mode. Safari
    /// follows for Full Disk Access users. Other Chromium forks stay on Manual
    /// import to avoid scanning the full default order.
    public static var mistralCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .firefox, .safari]
        #else
        nil
        #endif
    }
}
