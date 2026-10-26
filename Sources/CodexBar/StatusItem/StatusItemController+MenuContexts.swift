import AppKit
import CodexBarCore

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
