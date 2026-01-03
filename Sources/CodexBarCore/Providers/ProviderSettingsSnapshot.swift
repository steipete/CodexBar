import Foundation

public struct ProviderSettingsSnapshot: Sendable {
    public struct CodexProviderSettings: Sendable {
        public let usageDataSource: CodexUsageDataSource
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(
            usageDataSource: CodexUsageDataSource,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?)
        {
            self.usageDataSource = usageDataSource
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct ClaudeProviderSettings: Sendable {
        public let usageDataSource: ClaudeUsageDataSource
        public let webExtrasEnabled: Bool
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(
            usageDataSource: ClaudeUsageDataSource,
            webExtrasEnabled: Bool,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?)
        {
            self.usageDataSource = usageDataSource
            self.webExtrasEnabled = webExtrasEnabled
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct CursorProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct FactoryProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct MiniMaxProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct ZaiProviderSettings: Sendable {
        public init() {}
    }

    public struct CopilotProviderSettings: Sendable {
        public init() {}
    }

    public struct AugmentProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public let debugMenuEnabled: Bool
    public let codex: CodexProviderSettings?
    public let claude: ClaudeProviderSettings?
    public let cursor: CursorProviderSettings?
    public let factory: FactoryProviderSettings?
    public let minimax: MiniMaxProviderSettings?
    public let zai: ZaiProviderSettings?
    public let copilot: CopilotProviderSettings?
    public let augment: AugmentProviderSettings?

    public init(
        debugMenuEnabled: Bool,
        codex: CodexProviderSettings?,
        claude: ClaudeProviderSettings?,
        cursor: CursorProviderSettings?,
        factory: FactoryProviderSettings?,
        minimax: MiniMaxProviderSettings?,
        zai: ZaiProviderSettings?,
        copilot: CopilotProviderSettings?,
        augment: AugmentProviderSettings?)
    {
        self.debugMenuEnabled = debugMenuEnabled
        self.codex = codex
        self.claude = claude
        self.cursor = cursor
        self.factory = factory
        self.minimax = minimax
        self.zai = zai
        self.copilot = copilot
        self.augment = augment
    }
}
