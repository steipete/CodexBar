import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct HelmcodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .helmcode

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.helmcodeCookieSource
        _ = settings.helmcodeCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .helmcode(context.settings.helmcodeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.helmcodeCookieSource.rawValue },
            set: { raw in
                context.settings.helmcodeCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.helmcodeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports cloud.helmcode.com cookies from Chrome.",
                manual: "Paste a Cookie header or cURL capture from the Helmcode dashboard.",
                off: "Helmcode dashboard cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "helmcode-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports Helmcode dashboard cookies from Chrome.",
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "helmcode-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.helmcodeCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "helmcode-open-dashboard",
                        title: "Open Helmcode",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://cloud.helmcode.com/credits") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.helmcodeCookieSource == .manual },
                onActivate: { context.settings.ensureHelmcodeCookieLoaded() }),
        ]
    }
}
