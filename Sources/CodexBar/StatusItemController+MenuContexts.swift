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

    struct MenuPopulateSnapshot {
        let enabledProviders: [UsageProvider]
        let includesOverview: Bool
        let switcherSelection: ProviderSwitcherSelection?
        let selectedProvider: UsageProvider?
        let currentProvider: UsageProvider
        let codexAccountDisplay: CodexAccountMenuDisplay?
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let openAIContext: OpenAIWebContext
        let descriptor: MenuDescriptor
        let menuWidth: CGFloat

        var isOverviewSelected: Bool {
            self.switcherSelection == .overview
        }

        var menuUpdateContext: MenuUpdateContext {
            MenuUpdateContext(
                provider: self.selectedProvider,
                currentProvider: self.currentProvider,
                switcherSelection: self.switcherSelection ?? .provider(self.currentProvider),
                menuWidth: self.menuWidth,
                codexAccountDisplay: self.codexAccountDisplay,
                tokenAccountDisplay: self.tokenAccountDisplay,
                openAIContext: self.openAIContext,
                descriptor: self.descriptor)
        }

        var menuRebuildContext: MenuRebuildContext {
            MenuRebuildContext(
                enabledProviders: self.enabledProviders,
                includesOverview: self.includesOverview,
                switcherSelection: self.switcherSelection,
                currentProvider: self.currentProvider,
                selectedProvider: self.selectedProvider,
                menuWidth: self.menuWidth,
                codexAccountDisplay: self.codexAccountDisplay,
                tokenAccountDisplay: self.tokenAccountDisplay,
                openAIContext: self.openAIContext,
                descriptor: self.descriptor)
        }
    }

    struct MergedMenuSmartUpdateGate {
        let canSmartUpdate: Bool
        let canPreserveProviderSwitcher: Bool
        let providerSwitcherWidthMatches: Bool
    }
}
