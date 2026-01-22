import CodexBarCore
import Foundation

struct ProviderPresentationContext {
    let provider: UsageProvider
    let settings: SettingsStore
    let store: UsageStore
    let metadata: ProviderMetadata
}

struct ProviderAvailabilityContext {
    let provider: UsageProvider
    let settings: SettingsStore
    let environment: [String: String]
}

struct ProviderSourceLabelContext {
    let provider: UsageProvider
    let settings: SettingsStore
    let store: UsageStore
    let descriptor: ProviderDescriptor
}

struct ProviderSourceModeContext {
    let provider: UsageProvider
    let settings: SettingsStore
}

struct ProviderVersionContext {
    let provider: UsageProvider
    let browserDetection: BrowserDetection
}

struct ProviderSettingsSnapshotContext {
    let settings: SettingsStore
    let tokenOverride: TokenAccountOverride?
}
