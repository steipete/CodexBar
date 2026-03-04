import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct ManusProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .manus

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.manusCookieSource
        _ = settings.manusManualCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .manus(context.settings.manusSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.manusCookieSource.rawValue },
            set: { raw in
                context.settings.manusCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.manusCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste the session_id cookie value.",
                off: "Manus cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "manus-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "manus-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Paste your manus.im session_id cookie value here",
                binding: context.stringBinding(\.manusManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "manus-open-dashboard",
                        title: "Open Manus",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://manus.im") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.manusCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
