import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct ZoomMateProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zoommate

    /// ZoomMate is a web-cookie provider with no CLI/version detector, so the default detail line
    /// ("zoommate not detected") would misleadingly read as "provider not found". Match the other
    /// web-cookie providers (Cursor, Perplexity, Manus, …) and surface the source instead.
    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.zoomMateCookieSource
        _ = settings.zoomMateCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .zoommate(context.settings.zoomMateSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.zoomMateCookieSource.rawValue },
            set: { raw in
                context.settings.zoomMateCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.zoomMateCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatically signs in using your ZoomMate session cookies from Chrome.",
                manual: "Paste a cURL capture from the ZoomMate AI credit usage page.",
                off: "Paste a cURL capture from the ZoomMate AI credit usage page.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "zoommate-cookie-source",
                title: "Cookie source",
                subtitle: "Automatically signs in using your ZoomMate session cookies from Chrome.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .zoommate,
                        cookieSource: context.settings.zoomMateCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .zoommate,
                        cookieSource: { context.settings.zoomMateCookieSource },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "zoommate-cookie",
                title: "ZoomMate capture",
                subtitle: "Paste a full cURL capture from the ZoomMate AI credit usage page. " +
                    "The token expires approximately hourly, so you may need to re-paste periodically.",
                kind: .secure,
                placeholder: "curl 'https://ai.zoom.us/ai-computer/api/v1/credits/status' -H 'authorization: ...'",
                binding: context.stringBinding(\.zoomMateCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "zoommate-open-app",
                        title: "Open ZoomMate",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://zoommate.zoom.us/#/?settings=credit-usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.zoomMateCookieSource == .manual },
                onActivate: nil),
        ]
    }
}
