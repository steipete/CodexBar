import AppKit
import CodexBarCore

struct CachedMergedSwitcherMenuContent {
    let menuContentVersion: Int
    let menuWidth: CGFloat
    let codexAccountDisplay: CodexAccountMenuDisplay?
    let tokenAccountDisplay: TokenAccountMenuDisplay?
    let localizationSignature: String
    let items: [NSMenuItem]

    func matches(
        menuContentVersion: Int,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?,
        localizationSignature: String)
        -> Bool
    {
        self.menuContentVersion == menuContentVersion &&
            abs(self.menuWidth - menuWidth) <= 0.5 &&
            self.codexAccountDisplay == codexAccountDisplay &&
            self.tokenAccountDisplay == tokenAccountDisplay &&
            self.localizationSignature == localizationSignature
    }
}

extension StatusItemController {
    struct OpenAIWebContext {
        let hasUsageBreakdown: Bool
        let hasCreditsHistory: Bool
        let hasCostHistory: Bool
        let canShowBuyCredits: Bool
        let hasOpenAIWebMenuItems: Bool
    }

    struct MenuCardContext {
        let currentProvider: UsageProvider
        let selectedProvider: UsageProvider?
        let menuWidth: CGFloat
        let codexAccountDisplay: CodexAccountMenuDisplay?
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let openAIContext: OpenAIWebContext
    }

    struct MenuRebuildContext {
        let enabledProviders: [UsageProvider]
        let includesOverview: Bool
        let switcherSelection: ProviderSwitcherSelection?
        let currentProvider: UsageProvider
        let selectedProvider: UsageProvider?
        let menuWidth: CGFloat
        let codexAccountDisplay: CodexAccountMenuDisplay?
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let openAIContext: OpenAIWebContext
        let descriptor: MenuDescriptor
    }
}
