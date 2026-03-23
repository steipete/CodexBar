import CodexBarCore
import Foundation

@MainActor
final class CodexProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .codex

    func perform(action: ProviderRuntimeAction, context: ProviderRuntimeContext) async {
        switch action {
        case let .openAIWebAccessToggled(enabled):
            if enabled {
                // Clear stale cookie import errors when enabling per-account dashboard mode.
                if context.store.settings.codexMultipleAccountsEnabled {
                    context.store.openAIDashboardCookieImportStatus = nil
                }
            } else {
                context.store.resetOpenAIWebState()
            }
        case .forceSessionRefresh:
            break
        }
    }
}
