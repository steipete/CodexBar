import CodexBarCore
import Foundation

extension SettingsStore {
    var copilotAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .copilot)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .copilot, field: "apiKey", value: newValue)
        }
    }

    func ensureCopilotAPITokenLoaded() {
        self.migrateCopilotTokenToAccountIfNeeded()
    }

    func migrateCopilotTokenToAccountIfNeeded() {
        let token = self.copilotAPIToken
        guard !token.isEmpty else { return }
        let existing = self.tokenAccounts(for: .copilot)
        guard existing.isEmpty else { return }

        // Migration: move single config token to token accounts.
        // Store with fallback label synchronously, then enrich async.
        self.addTokenAccount(provider: .copilot, label: "Account 1", token: token)
        self.copilotAPIToken = ""

        // Best-effort async label enrichment
        Task { @MainActor in
            guard let account = self.tokenAccounts(for: .copilot).first else { return }
            do {
                let username = try await CopilotUsageFetcher.fetchGitHubUsername(token: token)
                self.removeTokenAccount(provider: .copilot, accountID: account.id)
                self.addTokenAccount(provider: .copilot, label: username, token: token)
            } catch {
                // Keep fallback label — migration still succeeded
            }
        }
    }
}

extension SettingsStore {
    func copilotSettingsSnapshot() -> ProviderSettingsSnapshot.CopilotProviderSettings {
        ProviderSettingsSnapshot.CopilotProviderSettings()
    }
}
