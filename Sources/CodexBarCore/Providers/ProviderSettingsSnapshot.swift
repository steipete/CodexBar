import Foundation

public struct ProviderSettingsSnapshot: Sendable {
    public static func make(
        debugMenuEnabled: Bool = false,
        debugKeepCLISessionsAlive: Bool = false,
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
        ollama: OllamaProviderSettings? = nil,
        jetbrains: JetBrainsProviderSettings? = nil) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot(
            debugMenuEnabled: debugMenuEnabled,
            debugKeepCLISessionsAlive: debugKeepCLISessionsAlive,
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
            ollama: ollama,
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

    public struct OllamaProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public let debugMenuEnabled: Bool
    public let debugKeepCLISessionsAlive: Bool
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
    public let ollama: OllamaProviderSettings?
    public let jetbrains: JetBrainsProviderSettings?

    public var jetbrainsIDEBasePath: String? {
        self.jetbrains?.ideBasePath
    }

    public init(
        debugMenuEnabled: Bool,
        debugKeepCLISessionsAlive: Bool,
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
        ollama: OllamaProviderSettings?,
        jetbrains: JetBrainsProviderSettings? = nil)
    {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
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
        self.ollama = ollama
        self.jetbrains = jetbrains
    }
}

public enum ProviderSettingsSnapshotContribution: Sendable {
    case codex(ProviderSettingsSnapshot.CodexProviderSettings)
    case claude(ProviderSettingsSnapshot.ClaudeProviderSettings)
    case cursor(ProviderSettingsSnapshot.CursorProviderSettings)
    case opencode(ProviderSettingsSnapshot.OpenCodeProviderSettings)
    case factory(ProviderSettingsSnapshot.FactoryProviderSettings)
    case minimax(ProviderSettingsSnapshot.MiniMaxProviderSettings)
    case zai(ProviderSettingsSnapshot.ZaiProviderSettings)
    case copilot(ProviderSettingsSnapshot.CopilotProviderSettings)
    case kimi(ProviderSettingsSnapshot.KimiProviderSettings)
    case augment(ProviderSettingsSnapshot.AugmentProviderSettings)
    case amp(ProviderSettingsSnapshot.AmpProviderSettings)
    case ollama(ProviderSettingsSnapshot.OllamaProviderSettings)
    case jetbrains(ProviderSettingsSnapshot.JetBrainsProviderSettings)
}

public struct ProviderSettingsSnapshotBuilder: Sendable {
    public var debugMenuEnabled: Bool
    public var debugKeepCLISessionsAlive: Bool
    public var codex: ProviderSettingsSnapshot.CodexProviderSettings?
    public var claude: ProviderSettingsSnapshot.ClaudeProviderSettings?
    public var cursor: ProviderSettingsSnapshot.CursorProviderSettings?
    public var opencode: ProviderSettingsSnapshot.OpenCodeProviderSettings?
    public var factory: ProviderSettingsSnapshot.FactoryProviderSettings?
    public var minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings?
    public var zai: ProviderSettingsSnapshot.ZaiProviderSettings?
    public var copilot: ProviderSettingsSnapshot.CopilotProviderSettings?
    public var kimi: ProviderSettingsSnapshot.KimiProviderSettings?
    public var augment: ProviderSettingsSnapshot.AugmentProviderSettings?
    public var amp: ProviderSettingsSnapshot.AmpProviderSettings?
    public var ollama: ProviderSettingsSnapshot.OllamaProviderSettings?
    public var jetbrains: ProviderSettingsSnapshot.JetBrainsProviderSettings?

    public init(debugMenuEnabled: Bool = false, debugKeepCLISessionsAlive: Bool = false) {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
    }

    public mutating func apply(_ contribution: ProviderSettingsSnapshotContribution) {
        switch contribution {
        case let .codex(value): self.codex = value
        case let .claude(value): self.claude = value
        case let .cursor(value): self.cursor = value
        case let .opencode(value): self.opencode = value
        case let .factory(value): self.factory = value
        case let .minimax(value): self.minimax = value
        case let .zai(value): self.zai = value
        case let .copilot(value): self.copilot = value
        case let .kimi(value): self.kimi = value
        case let .augment(value): self.augment = value
        case let .amp(value): self.amp = value
        case let .ollama(value): self.ollama = value
        case let .jetbrains(value): self.jetbrains = value
        }
    }

    public func build() -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            debugMenuEnabled: self.debugMenuEnabled,
            debugKeepCLISessionsAlive: self.debugKeepCLISessionsAlive,
            codex: self.codex,
            claude: self.claude,
            cursor: self.cursor,
            opencode: self.opencode,
            factory: self.factory,
            minimax: self.minimax,
            zai: self.zai,
            copilot: self.copilot,
            kimi: self.kimi,
            augment: self.augment,
            amp: self.amp,
            ollama: self.ollama,
            jetbrains: self.jetbrains)
    }
}
