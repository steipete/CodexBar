import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct AntigravityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .antigravity

    func detectVersion(context _: ProviderVersionContext) async -> String? {
        await AntigravityStatusProbe.detectVersion()
    }

    @MainActor
    func appendUsageMenuEntries(context _: ProviderMenuUsageContext, entries _: inout [ProviderMenuEntry]) {}

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runAntigravityLoginFlow()
        return false
    }
}
