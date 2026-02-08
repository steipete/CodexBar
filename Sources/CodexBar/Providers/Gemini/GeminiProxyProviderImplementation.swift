import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct GeminiProxyProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .geminiproxy

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.cliProxyGlobalBaseURL
        _ = settings.cliProxyGlobalManagementKey
        _ = settings.cliProxyGlobalAuthIndex
        _ = settings.codexCLIProxyBaseURL
        _ = settings.codexCLIProxyManagementKey
        _ = settings.codexCLIProxyAuthIndex
    }

    @MainActor
    func defaultSourceLabel(context _: ProviderSourceLabelContext) -> String? {
        "cliproxy-api"
    }

    @MainActor
    func sourceMode(context _: ProviderSourceModeContext) -> ProviderSourceMode {
        .api
    }
}
