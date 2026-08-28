import CodexBarCore
import Foundation

enum CopilotIconSecondaryWindowSelection {
    static let chat = "chat"
}

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

    var copilotEnterpriseHost: String {
        get { self.configSnapshot.providerConfig(for: .copilot)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }

    var copilotBudgetCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .copilot)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .copilot, field: "cookieHeader", value: newValue)
        }
    }

    var copilotBudgetCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .copilot, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .copilot, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureCopilotAPITokenLoaded() {}

    var copilotIconSecondaryWindowID: String {
        get {
            let raw = self.copilotIconSecondaryWindowIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? CopilotIconSecondaryWindowSelection.chat : raw
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.copilotIconSecondaryWindowIDRaw = trimmed.isEmpty
                ? CopilotIconSecondaryWindowSelection.chat
                : trimmed
        }
    }

    func copilotIconSecondaryWindowOverrideID(snapshot: UsageSnapshot?) -> String? {
        guard self.copilotBudgetExtrasEnabled else { return nil }
        let selected = self.copilotIconSecondaryWindowID
        guard selected != CopilotIconSecondaryWindowSelection.chat else { return nil }
        guard snapshot?.extraRateWindows?.contains(where: { $0.id == selected }) == true else { return nil }
        return selected
    }
}

extension SettingsStore {
    func copilotSettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CopilotProviderSettings
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .copilot,
            settings: self,
            override: tokenOverride)
        let token = account?.token ?? self.copilotAPIToken
        let host = CopilotDeviceFlow.normalizedHost(self.copilotEnterpriseHost)
        return ProviderSettingsSnapshot.CopilotProviderSettings(
            apiToken: self.normalizedConfigValue(token),
            enterpriseHost: host == CopilotDeviceFlow.defaultHost ? nil : host,
            selectedAccountExternalIdentifier: account?.externalIdentifier.flatMap(self.normalizedConfigValue),
            budgetExtrasEnabled: self.copilotBudgetExtrasEnabled,
            budgetCookieSource: self.copilotBudgetCookieSource,
            manualBudgetCookieHeader: self.normalizedConfigValue(self.copilotBudgetCookieHeader))
    }
}
