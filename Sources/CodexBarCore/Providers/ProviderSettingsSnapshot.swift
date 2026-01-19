import Foundation

public struct ProviderSettingsSnapshot: Sendable {
    public static func make(
        debugMenuEnabled: Bool = false,
        codex: CodexProviderSettings? = nil,
        claude: ClaudeProviderSettings? = nil,
        cursor: CursorProviderSettings? = nil,
        opencode: OpenCodeProviderSettings? = nil,
        factory: FactoryProviderSettings? = nil,
        minimax: MiniMaxProviderSettings? = nil,
        zai: ZaiProviderSettings? = nil,
        copilot: CopilotProviderSettings? = nil,
        kimi: KimiProviderSettings? = nil,
        augment: AugmentProviderSettings? = nil,
        amp: AmpProviderSettings? = nil,
        jetbrains: JetBrainsProviderSettings? = nil) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot(
            debugMenuEnabled: debugMenuEnabled,
            codex: codex,
            claude: claude,
            cursor: cursor,
            opencode: opencode,
            factory: factory,
            minimax: minimax,
            zai: zai,
            copilot: copilot,
            kimi: kimi,
            augment: augment,
            amp: amp,
            jetbrains: jetbrains)
    }

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

    public struct OpenCodeProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?
        public let workspaceID: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?, workspaceID: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.workspaceID = workspaceID
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
        public let apiRegion: MiniMaxAPIRegion

        public init(
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?,
            apiRegion: MiniMaxAPIRegion = .global)
        {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.apiRegion = apiRegion
        }
    }

    public struct ZaiProviderSettings: Sendable {
        public let apiRegion: ZaiAPIRegion

        public init(apiRegion: ZaiAPIRegion = .global) {
            self.apiRegion = apiRegion
        }
    }

    public struct CopilotProviderSettings: Sendable {
        public init() {}
    }

    public struct KimiProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct AugmentProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct JetBrainsProviderSettings: Sendable {
        public let ideBasePath: String?

        public init(ideBasePath: String?) {
            self.ideBasePath = ideBasePath
        }
    }

    public struct AmpProviderSettings: Sendable {
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
    public let opencode: OpenCodeProviderSettings?
    public let factory: FactoryProviderSettings?
    public let minimax: MiniMaxProviderSettings?
    public let zai: ZaiProviderSettings?
    public let copilot: CopilotProviderSettings?
    public let kimi: KimiProviderSettings?
    public let augment: AugmentProviderSettings?
    public let amp: AmpProviderSettings?
    public let jetbrains: JetBrainsProviderSettings?

    public var jetbrainsIDEBasePath: String? {
        self.jetbrains?.ideBasePath
    }

    public init(
        debugMenuEnabled: Bool,
        codex: CodexProviderSettings?,
        claude: ClaudeProviderSettings?,
        cursor: CursorProviderSettings?,
        opencode: OpenCodeProviderSettings?,
        factory: FactoryProviderSettings?,
        minimax: MiniMaxProviderSettings?,
        zai: ZaiProviderSettings?,
        copilot: CopilotProviderSettings?,
        kimi: KimiProviderSettings?,
        augment: AugmentProviderSettings?,
        amp: AmpProviderSettings?,
        jetbrains: JetBrainsProviderSettings? = nil)
    {
        self.debugMenuEnabled = debugMenuEnabled
        self.codex = codex
        self.claude = claude
        self.cursor = cursor
        self.opencode = opencode
        self.factory = factory
        self.minimax = minimax
        self.zai = zai
        self.copilot = copilot
        self.kimi = kimi
        self.augment = augment
        self.amp = amp
        self.jetbrains = jetbrains
    }
}
