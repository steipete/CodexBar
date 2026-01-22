import CodexBarCore
import Foundation

typealias ProviderMenuEntry = MenuDescriptor.Entry

struct ProviderMenuUsageContext {
    let provider: UsageProvider
    let store: UsageStore
    let settings: SettingsStore
    let metadata: ProviderMetadata
    let snapshot: UsageSnapshot?
}

struct ProviderMenuActionContext {
    let provider: UsageProvider
    let store: UsageStore
    let settings: SettingsStore
    let account: AccountInfo
}

struct ProviderMenuLoginContext {
    let provider: UsageProvider
    let store: UsageStore
    let settings: SettingsStore
    let account: AccountInfo
}
