import CodexBarCore
import Foundation

struct ProviderRuntimeContext {
    let provider: UsageProvider
    let settings: SettingsStore
    let store: UsageStore
}

enum ProviderRuntimeAction: Sendable {
    case forceSessionRefresh
    case openAIWebAccessToggled(Bool)
}

@MainActor
protocol ProviderRuntime: AnyObject {
    var id: UsageProvider { get }

    func start(context: ProviderRuntimeContext)
    func stop(context: ProviderRuntimeContext)
    func settingsDidChange(context: ProviderRuntimeContext)
    func providerDidRefresh(context: ProviderRuntimeContext, provider: UsageProvider)
    func providerDidFail(context: ProviderRuntimeContext, provider: UsageProvider, error: Error)
    func perform(action: ProviderRuntimeAction, context: ProviderRuntimeContext) async
}

extension ProviderRuntime {
    func start(context _: ProviderRuntimeContext) {}
    func stop(context _: ProviderRuntimeContext) {}
    func settingsDidChange(context _: ProviderRuntimeContext) {}
    func providerDidRefresh(context _: ProviderRuntimeContext, provider _: UsageProvider) {}
    func providerDidFail(context _: ProviderRuntimeContext, provider _: UsageProvider, error _: Error) {}
    func perform(action _: ProviderRuntimeAction, context _: ProviderRuntimeContext) async {}
}
