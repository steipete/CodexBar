import AppKit
import CodexBarCore

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
}

struct TokenAccountMenuDisplay {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let showAll: Bool
    let showSwitcher: Bool
}

struct CodexAccountMenuDisplay {
    let accounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
}

struct OpenAIWebContext {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let hasOpenAIWebMenuItems: Bool
}

struct MenuCardContext {
    let currentProvider: UsageProvider
    let selectedProvider: UsageProvider?
    let menuWidth: CGFloat
    let showsHeaderEmail: Bool
    let tokenAccountDisplay: TokenAccountMenuDisplay?
    let openAIContext: OpenAIWebContext
}
