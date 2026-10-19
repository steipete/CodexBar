import CodexBarCore
import Foundation

extension SettingsStore {
    var opencodegoWorkspaceID: String {
        get { self.configSnapshot.providerConfig(for: .opencodego)?.workspaceID ?? "" }
        set { self[providerConfig: .opencodego, field: .workspace] = newValue }
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
            tokenOverride: tokenOverride)
        return ProviderSettingsSnapshot.OpenCodeProviderSettings(
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader,
            workspaceID: self.providerConfig(for: .opencodego)?.sanitizedWorkspaceID)
    }
}
