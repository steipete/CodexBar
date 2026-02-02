import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct TraeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .trae

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.traeCookieHeader
        _ = settings.tokenAccounts(for: .trae)
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .trae(context.settings.traeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    // No settingsPickers - Trae only supports manual JWT entry
    // The JWT is not stored in browser cookies, only in HTTP headers

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "trae-jwt-token",
                title: "JWT Token",
                subtitle: "Paste Authorization header from browser DevTools. Instructions:\n1. Open trae.ai and log in\n2. Open DevTools → Network tab\n3. Find request to 'user_current_entitlement_list'\n4. Copy 'Authorization' header (starts with 'Cloud-IDE-JWT')\n5. Paste here",
                kind: .secure,
                placeholder: "Cloud-IDE-JWT eyJ...",
                binding: context.stringBinding(\.traeCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "trae-open-settings",
                        title: "Open Trae Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.trae.ai/account-setting") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { true },
                onActivate: { context.settings.ensureTraeCookieLoaded() }),
        ]
    }
}
