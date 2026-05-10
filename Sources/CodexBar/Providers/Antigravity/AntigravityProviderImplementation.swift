import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AntigravityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .antigravity
    let supportsLoginFlow: Bool = true

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.antigravityUsageDataSource
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.antigravityUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.antigravityUsageDataSource {
        case .auto: .auto
        case .oauth: .oauth
        case .cli: .cli
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.antigravityUsageDataSource.rawValue },
            set: { raw in
                context.settings.antigravityUsageDataSource = AntigravityUsageDataSource(rawValue: raw) ?? .auto
            })
        let usageOptions = AntigravityUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "antigravity-usage-source",
                title: "Usage source",
                subtitle: "Auto uses the local IDE API first, then Google OAuth when the IDE is closed.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.antigravityUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .antigravity)
                    return label == "auto" ? nil : label
                }),
        ]
    }

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        let credentialsPath = AntigravityOAuthCredentialsStore().fileURL.path
        let credentialsExist = FileManager.default.fileExists(atPath: credentialsPath)
        let loginTitle = credentialsExist ? "Re-authenticate" : "Login with Google"
        let subtitle = """
        Stores credentials in ~/.codexbar/antigravity/oauth_creds.json. Uses Antigravity.app OAuth when available, \
        or ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET as an override.
        """
        return [
            ProviderSettingsActionsDescriptor(
                id: "antigravity-oauth",
                title: "Google OAuth",
                subtitle: subtitle,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "antigravity-oauth-login",
                        title: loginTitle,
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            await context.runLoginFlow()
                        }),
                ],
                isVisible: nil),
        ]
    }

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
