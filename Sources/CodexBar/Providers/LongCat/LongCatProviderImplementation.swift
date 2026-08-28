import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct LongCatProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .longcat

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.longcatUsageDataSource
        _ = settings.longcatCookieSource
        _ = settings.longcatManualCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .longcat(context.settings.longcatSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.longcatUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.longcatUsageDataSource {
        case .web: .web
        case .auto, .api, .cli, .oauth: .auto
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.longcatCookieSource.rawValue },
            set: { raw in
                context.settings.longcatCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.longcatCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports longcat.chat cookies from your browser.",
                manual: "Paste a Cookie header copied from longcat.chat.",
                off: "LongCat cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "longcat-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports longcat.chat cookies from your browser.",
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
                id: "longcat-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}",
                binding: context.stringBinding(\.longcatManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "longcat-open-console",
                        title: "Open Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://longcat.chat/platform/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.longcatCookieSource == .manual },
                onActivate: { context.settings.ensureLongCatCookieLoaded() }),
        ]
    }
}
