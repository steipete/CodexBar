import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct PoeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .poe

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.poeToken(environment: context.environment) != nil
    }

    @MainActor
    func sourceMode(context _: ProviderSourceModeContext) -> ProviderSourceMode {
        .api
    }
}
