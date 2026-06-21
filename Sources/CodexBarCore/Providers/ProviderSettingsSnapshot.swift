import Foundation

public protocol ProviderCookieSettings: Sendable {
    var cookieSource: ProviderCookieSource { get }
    var manualCookieHeader: String? { get }

    init(cookieSource: ProviderCookieSource, manualCookieHeader: String?)
}

public struct ProviderSettingsSnapshot: Sendable {
    public static func make(
        debugMenuEnabled: Bool = false,
        debugKeepCLISessionsAlive: Bool = false,
        codex: CodexProviderSettings? = nil,
        claude: ClaudeProviderSettings? = nil,
        cursor: CursorProviderSettings? = nil,
        opencode: OpenCodeProviderSettings? = nil,
        opencodego: OpenCodeProviderSettings? = nil,
        alibaba: AlibabaCodingPlanProviderSettings? = nil,
        alibabaTokenPlan: AlibabaTokenPlanProviderSettings? = nil,
        factory: FactoryProviderSettings? = nil,
        minimax: MiniMaxProviderSettings? = nil,
        manus: ManusProviderSettings? = nil,
        zai: ZaiProviderSettings? = nil,
        copilot: CopilotProviderSettings? = nil,
        kilo: KiloProviderSettings? = nil,
        kimi: KimiProviderSettings? = nil,
        augment: AugmentProviderSettings? = nil,
        moonshot: MoonshotProviderSettings? = nil,
        amp: AmpProviderSettings? = nil,
        t3chat: T3ChatProviderSettings? = nil,
        devin: DevinProviderSettings? = nil,
        commandcode: CommandCodeProviderSettings? = nil,
        ollama: OllamaProviderSettings? = nil,
        jetbrains: JetBrainsProviderSettings? = nil,
        windsurf: WindsurfProviderSettings? = nil,
        perplexity: PerplexityProviderSettings? = nil,
        mimo: MiMoProviderSettings? = nil,
        abacus: AbacusProviderSettings? = nil,
        mistral: MistralProviderSettings? = nil,
        stepfun: StepFunProviderSettings? = nil) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot(
            debugMenuEnabled: debugMenuEnabled,
            debugKeepCLISessionsAlive: debugKeepCLISessionsAlive,
            codex: codex,
            claude: claude,
            cursor: cursor,
            opencode: opencode,
            opencodego: opencodego,
            alibaba: alibaba,
            alibabaTokenPlan: alibabaTokenPlan,
            factory: factory,
            minimax: minimax,
            manus: manus,
            zai: zai,
            copilot: copilot,
            kilo: kilo,
            kimi: kimi,
            augment: augment,
            moonshot: moonshot,
            amp: amp,
            t3chat: t3chat,
            devin: devin,
            commandcode: commandcode,
            ollama: ollama,
            jetbrains: jetbrains,
            windsurf: windsurf,
            perplexity: perplexity,
            mimo: mimo,
            abacus: abacus,
            mistral: mistral,
            stepfun: stepfun)
    }

    public struct CodexProviderSettings: Sendable {
        public let usageDataSource: CodexUsageDataSource
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?
        public let managedAccountStoreUnreadable: Bool
        public let managedAccountTargetUnavailable: Bool
        public let profileAccountTargetUnavailable: Bool
        public let openAIWebCacheScope: CookieHeaderCache.Scope?
        public let dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate]

        public init(
            usageDataSource: CodexUsageDataSource,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?,
            managedAccountStoreUnreadable: Bool = false,
            managedAccountTargetUnavailable: Bool = false,
            profileAccountTargetUnavailable: Bool = false,
            openAIWebCacheScope: CookieHeaderCache.Scope? = nil,
            dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate] = [])
        {
            self.usageDataSource = usageDataSource
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.managedAccountStoreUnreadable = managedAccountStoreUnreadable
            self.managedAccountTargetUnavailable = managedAccountTargetUnavailable
            self.profileAccountTargetUnavailable = profileAccountTargetUnavailable
            self.openAIWebCacheScope = openAIWebCacheScope
            self.dashboardAuthorityKnownOwners = dashboardAuthorityKnownOwners
        }
    }

    public struct ClaudeProviderSettings: Sendable {
        public let usageDataSource: ClaudeUsageDataSource
        public let webExtrasEnabled: Bool
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?
        public let organizationID: String?

        public init(
            usageDataSource: ClaudeUsageDataSource,
            webExtrasEnabled: Bool,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?,
            organizationID: String? = nil)
        {
            self.usageDataSource = usageDataSource
            self.webExtrasEnabled = webExtrasEnabled
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.organizationID = organizationID
        }
    }

    public struct CookieProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource = .auto, manualCookieHeader: String? = nil) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct CursorProviderSettings: ProviderCookieSettings {
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

    public struct AlibabaCodingPlanProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?
        public let apiRegion: AlibabaCodingPlanAPIRegion

        public init(
            cookieSource: ProviderCookieSource = .auto,
            manualCookieHeader: String? = nil,
            apiRegion: AlibabaCodingPlanAPIRegion = .international)
        {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.apiRegion = apiRegion
        }
    }

    public struct AlibabaTokenPlanProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource = .auto, manualCookieHeader: String? = nil) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct FactoryProviderSettings: ProviderCookieSettings {
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

    public struct ManusProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct ZaiProviderSettings: Sendable {
        public let apiRegion: ZaiAPIRegion
        public let usageScope: ZaiUsageScope
        public let teamContext: ZaiBigModelTeamContext?

        public init(
            apiRegion: ZaiAPIRegion = .global,
            usageScope: ZaiUsageScope = .personal,
            teamContext: ZaiBigModelTeamContext? = nil)
        {
            self.apiRegion = apiRegion
            self.usageScope = usageScope
            self.teamContext = teamContext
        }
    }

    public struct CopilotProviderSettings: Sendable {
        public let apiToken: String?
        public let enterpriseHost: String?
        public let selectedAccountExternalIdentifier: String?
        public let budgetExtrasEnabled: Bool
        public let budgetCookieSource: ProviderCookieSource
        public let manualBudgetCookieHeader: String?

        public init(
            apiToken: String? = nil,
            enterpriseHost: String? = nil,
            selectedAccountExternalIdentifier: String? = nil,
            budgetExtrasEnabled: Bool = false,
            budgetCookieSource: ProviderCookieSource = .auto,
            manualBudgetCookieHeader: String? = nil)
        {
            self.apiToken = apiToken
            self.enterpriseHost = enterpriseHost
            self.selectedAccountExternalIdentifier = selectedAccountExternalIdentifier
            self.budgetExtrasEnabled = budgetExtrasEnabled
            self.budgetCookieSource = budgetCookieSource
            self.manualBudgetCookieHeader = manualBudgetCookieHeader
        }
    }

    public struct KiloProviderSettings: Sendable {
        public let usageDataSource: KiloUsageDataSource
        public let extrasEnabled: Bool

        public init(usageDataSource: KiloUsageDataSource, extrasEnabled: Bool) {
            self.usageDataSource = usageDataSource
            self.extrasEnabled = extrasEnabled
        }
    }

    public struct KimiProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct AugmentProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct MoonshotProviderSettings: Sendable {
        public let region: MoonshotRegion?

        public init(region: MoonshotRegion? = nil) {
            self.region = region
        }
    }

    public struct JetBrainsProviderSettings: Sendable {
        public let ideBasePath: String?

        public init(ideBasePath: String?) {
            self.ideBasePath = ideBasePath
        }
    }

    public struct AmpProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct T3ChatProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct DevinProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualBearerToken: String?
        public let organization: String?

        public init(cookieSource: ProviderCookieSource, manualBearerToken: String?, organization: String?) {
            self.cookieSource = cookieSource
            self.manualBearerToken = manualBearerToken
            self.organization = organization
        }
    }

    public struct CommandCodeProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct OllamaProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct WindsurfProviderSettings: Sendable {
        public let usageDataSource: WindsurfUsageDataSource
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(
            usageDataSource: WindsurfUsageDataSource,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?)
        {
            self.usageDataSource = usageDataSource
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct PerplexityProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct MiMoProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct AbacusProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct MistralProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public struct StepFunProviderSettings: Sendable {
        public let cookieSource: ProviderCookieSource
        public let manualToken: String
        public let username: String
        public let password: String

        public init(
            cookieSource: ProviderCookieSource = .auto,
            manualToken: String = "",
            username: String = "",
            password: String = "")
        {
            self.cookieSource = cookieSource
            self.manualToken = manualToken
            self.username = username
            self.password = password
        }
    }

    public let debugMenuEnabled: Bool
    public let debugKeepCLISessionsAlive: Bool
    public let codex: CodexProviderSettings?
    public let claude: ClaudeProviderSettings?
    public let cursor: CursorProviderSettings?
    public let opencode: OpenCodeProviderSettings?
    public let opencodego: OpenCodeProviderSettings?
    public let alibaba: AlibabaCodingPlanProviderSettings?
    public let alibabaTokenPlan: AlibabaTokenPlanProviderSettings?
    public let factory: FactoryProviderSettings?
    public let minimax: MiniMaxProviderSettings?
    public let manus: ManusProviderSettings?
    public let zai: ZaiProviderSettings?
    public let copilot: CopilotProviderSettings?
    public let kilo: KiloProviderSettings?
    public let kimi: KimiProviderSettings?
    public let augment: AugmentProviderSettings?
    public let moonshot: MoonshotProviderSettings?
    public let amp: AmpProviderSettings?
    public let t3chat: T3ChatProviderSettings?
    public let devin: DevinProviderSettings?
    public let commandcode: CommandCodeProviderSettings?
    public let ollama: OllamaProviderSettings?
    public let jetbrains: JetBrainsProviderSettings?
    public let windsurf: WindsurfProviderSettings?
    public let perplexity: PerplexityProviderSettings?
    public let mimo: MiMoProviderSettings?
    public let abacus: AbacusProviderSettings?
    public let mistral: MistralProviderSettings?
    public let stepfun: StepFunProviderSettings?

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
        opencodego: OpenCodeProviderSettings?,
        alibaba: AlibabaCodingPlanProviderSettings?,
        alibabaTokenPlan: AlibabaTokenPlanProviderSettings? = nil,
        factory: FactoryProviderSettings?,
        minimax: MiniMaxProviderSettings?,
        manus: ManusProviderSettings?,
        zai: ZaiProviderSettings?,
        copilot: CopilotProviderSettings?,
        kilo: KiloProviderSettings?,
        kimi: KimiProviderSettings?,
        augment: AugmentProviderSettings?,
        moonshot: MoonshotProviderSettings? = nil,
        amp: AmpProviderSettings?,
        t3chat: T3ChatProviderSettings? = nil,
        devin: DevinProviderSettings? = nil,
        commandcode: CommandCodeProviderSettings? = nil,
        ollama: OllamaProviderSettings?,
        jetbrains: JetBrainsProviderSettings? = nil,
        windsurf: WindsurfProviderSettings? = nil,
        perplexity: PerplexityProviderSettings? = nil,
        mimo: MiMoProviderSettings? = nil,
        abacus: AbacusProviderSettings? = nil,
        mistral: MistralProviderSettings? = nil,
        stepfun: StepFunProviderSettings? = nil)
    {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
        self.codex = codex
        self.claude = claude
        self.cursor = cursor
        self.opencode = opencode
        self.opencodego = opencodego
        self.alibaba = alibaba
        self.alibabaTokenPlan = alibabaTokenPlan
        self.factory = factory
        self.minimax = minimax
        self.manus = manus
        self.zai = zai
        self.copilot = copilot
        self.kilo = kilo
        self.kimi = kimi
        self.augment = augment
        self.moonshot = moonshot
        self.amp = amp
        self.t3chat = t3chat
        self.devin = devin
        self.commandcode = commandcode
        self.ollama = ollama
        self.jetbrains = jetbrains
        self.windsurf = windsurf
        self.perplexity = perplexity
        self.mimo = mimo
        self.abacus = abacus
        self.mistral = mistral
        self.stepfun = stepfun
    }
}

public enum ProviderSettingsSnapshotContribution: Sendable {
    case codex(ProviderSettingsSnapshot.CodexProviderSettings)
    case claude(ProviderSettingsSnapshot.ClaudeProviderSettings)
    case cursor(ProviderSettingsSnapshot.CursorProviderSettings)
    case opencode(ProviderSettingsSnapshot.OpenCodeProviderSettings)
    case opencodego(ProviderSettingsSnapshot.OpenCodeProviderSettings)
    case alibaba(ProviderSettingsSnapshot.AlibabaCodingPlanProviderSettings)
    case alibabaTokenPlan(ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings)
    case factory(ProviderSettingsSnapshot.FactoryProviderSettings)
    case minimax(ProviderSettingsSnapshot.MiniMaxProviderSettings)
    case manus(ProviderSettingsSnapshot.ManusProviderSettings)
    case zai(ProviderSettingsSnapshot.ZaiProviderSettings)
    case copilot(ProviderSettingsSnapshot.CopilotProviderSettings)
    case kilo(ProviderSettingsSnapshot.KiloProviderSettings)
    case kimi(ProviderSettingsSnapshot.KimiProviderSettings)
    case augment(ProviderSettingsSnapshot.AugmentProviderSettings)
    case moonshot(ProviderSettingsSnapshot.MoonshotProviderSettings)
    case amp(ProviderSettingsSnapshot.AmpProviderSettings)
    case t3chat(ProviderSettingsSnapshot.T3ChatProviderSettings)
    case devin(ProviderSettingsSnapshot.DevinProviderSettings)
    case commandcode(ProviderSettingsSnapshot.CommandCodeProviderSettings)
    case ollama(ProviderSettingsSnapshot.OllamaProviderSettings)
    case jetbrains(ProviderSettingsSnapshot.JetBrainsProviderSettings)
    case windsurf(ProviderSettingsSnapshot.WindsurfProviderSettings)
    case perplexity(ProviderSettingsSnapshot.PerplexityProviderSettings)
    case mimo(ProviderSettingsSnapshot.MiMoProviderSettings)
    case abacus(ProviderSettingsSnapshot.AbacusProviderSettings)
    case mistral(ProviderSettingsSnapshot.MistralProviderSettings)
    case stepfun(ProviderSettingsSnapshot.StepFunProviderSettings)
}

public struct ProviderSettingsSnapshotBuilder: Sendable {
    public var debugMenuEnabled: Bool
    public var debugKeepCLISessionsAlive: Bool
    public var codex: ProviderSettingsSnapshot.CodexProviderSettings?
    public var claude: ProviderSettingsSnapshot.ClaudeProviderSettings?
    public var cursor: ProviderSettingsSnapshot.CursorProviderSettings?
    public var opencode: ProviderSettingsSnapshot.OpenCodeProviderSettings?
    public var opencodego: ProviderSettingsSnapshot.OpenCodeProviderSettings?
    public var alibaba: ProviderSettingsSnapshot.AlibabaCodingPlanProviderSettings?
    public var alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings?
    public var factory: ProviderSettingsSnapshot.FactoryProviderSettings?
    public var minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings?
    public var manus: ProviderSettingsSnapshot.ManusProviderSettings?
    public var zai: ProviderSettingsSnapshot.ZaiProviderSettings?
    public var copilot: ProviderSettingsSnapshot.CopilotProviderSettings?
    public var kilo: ProviderSettingsSnapshot.KiloProviderSettings?
    public var kimi: ProviderSettingsSnapshot.KimiProviderSettings?
    public var augment: ProviderSettingsSnapshot.AugmentProviderSettings?
    public var moonshot: ProviderSettingsSnapshot.MoonshotProviderSettings?
    public var amp: ProviderSettingsSnapshot.AmpProviderSettings?
    public var t3chat: ProviderSettingsSnapshot.T3ChatProviderSettings?
    public var devin: ProviderSettingsSnapshot.DevinProviderSettings?
    public var commandcode: ProviderSettingsSnapshot.CommandCodeProviderSettings?
    public var ollama: ProviderSettingsSnapshot.OllamaProviderSettings?
    public var jetbrains: ProviderSettingsSnapshot.JetBrainsProviderSettings?
    public var windsurf: ProviderSettingsSnapshot.WindsurfProviderSettings?
    public var perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings?
    public var mimo: ProviderSettingsSnapshot.MiMoProviderSettings?
    public var abacus: ProviderSettingsSnapshot.AbacusProviderSettings?
    public var mistral: ProviderSettingsSnapshot.MistralProviderSettings?
    public var stepfun: ProviderSettingsSnapshot.StepFunProviderSettings?

    public init(debugMenuEnabled: Bool = false, debugKeepCLISessionsAlive: Bool = false) {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
    }

    // swiftlint:disable:next cyclomatic_complexity
    public mutating func apply(_ contribution: ProviderSettingsSnapshotContribution) {
        switch contribution {
        case let .codex(value): self.codex = value
        case let .claude(value): self.claude = value
        case let .cursor(value): self.cursor = value
        case let .opencode(value): self.opencode = value
        case let .opencodego(value): self.opencodego = value
        case let .alibaba(value): self.alibaba = value
        case let .alibabaTokenPlan(value): self.alibabaTokenPlan = value
        case let .factory(value): self.factory = value
        case let .minimax(value): self.minimax = value
        case let .manus(value): self.manus = value
        case let .zai(value): self.zai = value
        case let .copilot(value): self.copilot = value
        case let .kilo(value): self.kilo = value
        case let .kimi(value): self.kimi = value
        case let .augment(value): self.augment = value
        case let .moonshot(value): self.moonshot = value
        case let .amp(value): self.amp = value
        case let .t3chat(value): self.t3chat = value
        case let .devin(value): self.devin = value
        case let .commandcode(value): self.commandcode = value
        case let .ollama(value): self.ollama = value
        case let .jetbrains(value): self.jetbrains = value
        case let .windsurf(value): self.windsurf = value
        case let .perplexity(value): self.perplexity = value
        case let .mimo(value): self.mimo = value
        case let .abacus(value): self.abacus = value
        case let .mistral(value): self.mistral = value
        case let .stepfun(value): self.stepfun = value
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
            opencodego: self.opencodego,
            alibaba: self.alibaba,
            alibabaTokenPlan: self.alibabaTokenPlan,
            factory: self.factory,
            minimax: self.minimax,
            manus: self.manus,
            zai: self.zai,
            copilot: self.copilot,
            kilo: self.kilo,
            kimi: self.kimi,
            augment: self.augment,
            moonshot: self.moonshot,
            amp: self.amp,
            t3chat: self.t3chat,
            devin: self.devin,
            commandcode: self.commandcode,
            ollama: self.ollama,
            jetbrains: self.jetbrains,
            windsurf: self.windsurf,
            perplexity: self.perplexity,
            mimo: self.mimo,
            abacus: self.abacus,
            mistral: self.mistral,
            stepfun: self.stepfun)
    }
}
