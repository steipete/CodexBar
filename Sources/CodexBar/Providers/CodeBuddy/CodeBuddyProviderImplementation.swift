import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct CodeBuddyProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .codebuddy

    func makeRuntime() -> (any ProviderRuntime)? {
        CodeBuddyProviderRuntime()
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.codebuddyCookieSource
        _ = settings.codebuddyManualCookieHeader
        _ = settings.codebuddyEnterpriseID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .codebuddy(context.settings.codebuddySettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.codebuddyCookieSource.rawValue },
            set: { raw in
                context.settings.codebuddyCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.codebuddyCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a cookie header from the dashboard.",
                off: "CodeBuddy cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "codebuddy-cookie-source",
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
                id: "codebuddy-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: session=\u{2026}",
                binding: context.stringBinding(\.codebuddyManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "codebuddy-open-dashboard",
                        title: "Open Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://tencent.sso.codebuddy.cn/profile/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.codebuddyCookieSource == .manual },
                onActivate: { context.settings.ensureCodeBuddySessionLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "codebuddy-enterprise-id",
                title: "Enterprise ID",
                subtitle: "Default: etahzsqej0n4 (only change if you have a different enterprise)",
                kind: .plain,
                placeholder: "etahzsqej0n4",
                binding: context.stringBinding(\.codebuddyEnterpriseID),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
