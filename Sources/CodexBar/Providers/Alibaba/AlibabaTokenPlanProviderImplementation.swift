import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AlibabaTokenPlanProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .alibabatokenplan

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.alibabaTokenPlanCookieSource
        _ = settings.alibabaTokenPlanCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return .alibabaTokenPlan(context.settings.alibabaTokenPlanSettingsSnapshot())
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.alibabaTokenPlanCookieSource.rawValue },
            set: { raw in
                context.settings.alibabaTokenPlanCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.alibabaTokenPlanCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies from Bailian.",
                manual: "Paste a Cookie header from bailian.console.aliyun.com.",
                off: "Alibaba Token Plan cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "alibaba-token-plan-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies from Bailian.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .alibabatokenplan) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "alibaba-token-plan-cookie",
                title: "Cookie header",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.alibabaTokenPlanCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "alibaba-token-plan-open-dashboard",
                        title: "Open Token Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(AlibabaTokenPlanUsageFetcher.dashboardURL)
                        }),
                ],
                isVisible: {
                    context.settings.alibabaTokenPlanCookieSource == .manual
                },
                onActivate: nil),
        ]
    }
}
