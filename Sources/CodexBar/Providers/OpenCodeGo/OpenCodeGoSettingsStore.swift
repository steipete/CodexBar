import CodexBarCore
import Foundation

extension SettingsStore {
    var opencodegoWorkspaceID: String {
        get { self.configSnapshot.providerConfig(for: .opencodego)?.workspaceID ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed
            self.updateProviderConfig(provider: .opencodego) { entry in
                entry.workspaceID = value
            }
        }
    }

    var opencodegoCookieHeader: String {
        get { self[providerConfig: .opencodego, field: .cookieHeader] }
        set { self[providerConfig: .opencodego, field: .cookieHeader] = newValue }
    }

    var opencodegoCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .opencodego, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .opencodego) }
    }

    var opencodegoDashboardURL: URL {
        OpenCodeGoUsageFetcher.dashboardURL(workspaceID: self.opencodegoWorkspaceID)
    }
}

extension SettingsStore {
    func opencodegoSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .OpenCodeProviderSettings
    {
        let cookieSettings: ProviderSettingsSnapshot.CookieProviderSettings = self.resolvedCookieSettings(
            provider: .opencodego,
            configuredSource: self.opencodegoCookieSource,
            configuredHeader: self.opencodegoCookieHeader,
            tokenOverride: tokenOverride)
        return ProviderSettingsSnapshot.OpenCodeProviderSettings(
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader,
            workspaceID: self.opencodegoSnapshotWorkspaceID)
    }

    private var opencodegoSnapshotWorkspaceID: String? {
        guard let workspaceID = self.configSnapshot.providerConfig(for: .opencodego)?.workspaceID else {
            return nil
        }
        let trimmed = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
