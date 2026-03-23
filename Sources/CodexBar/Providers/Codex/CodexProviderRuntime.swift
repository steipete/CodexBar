import CodexBarCore
import Foundation

@MainActor
final class CodexProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .codex

    private struct CredentialState: Equatable {
        let cookieSource: ProviderCookieSource
        let hasManualCookieHeader: Bool
        let hasTokenAccounts: Bool
        let selectedTokenAccountID: UUID?

        var hasManualCredentials: Bool {
            self.hasManualCookieHeader || self.hasTokenAccounts
        }

        @MainActor
        static func capture(from settings: SettingsStore) -> Self {
            let manualHeader = settings.codexCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(
                cookieSource: settings.codexCookieSource,
                hasManualCookieHeader: !manualHeader.isEmpty,
                hasTokenAccounts: !settings.tokenAccounts(for: .codex).isEmpty,
                selectedTokenAccountID: settings.selectedTokenAccount(for: .codex)?.id)
        }
    }

    private var lastCredentialState: CredentialState?

    func settingsDidChange(context: ProviderRuntimeContext) {
        let current = CredentialState.capture(from: context.settings)
        defer { self.lastCredentialState = current }

        guard let previous = self.lastCredentialState else { return }
        guard previous != current else { return }

        let removedAllManualCodexCredentials =
            previous.cookieSource == .manual &&
            previous.hasManualCredentials &&
            current.cookieSource == .manual &&
            !current.hasManualCredentials

        let disabledOpenAIWeb = previous.cookieSource.isEnabled && !current.cookieSource.isEnabled

        guard removedAllManualCodexCredentials || disabledOpenAIWeb else { return }

        CookieHeaderCache.clear(provider: .codex)
        OpenAIDashboardCacheStore.clear()
        context.store.resetOpenAIWebState()
    }

    func perform(action: ProviderRuntimeAction, context: ProviderRuntimeContext) async {
        switch action {
        case let .openAIWebAccessToggled(enabled):
            guard enabled == false else { return }
            CookieHeaderCache.clear(provider: .codex)
            OpenAIDashboardCacheStore.clear()
            context.store.resetOpenAIWebState()
        case .forceSessionRefresh:
            break
        }
    }
}
