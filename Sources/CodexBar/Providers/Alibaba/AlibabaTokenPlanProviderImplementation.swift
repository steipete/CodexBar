import AppKit
import CodexBarCore
import Foundation
import SwiftUI

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
        _ = settings.alibabaTokenPlanAPIRegion
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
            let host = context.settings.alibabaTokenPlanAPIRegion.dashboardURL.host ?? "the selected console"
            return ProviderCookieSourceUI.subtitle(
                source: context.settings.alibabaTokenPlanCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies from Model Studio/Bailian.",
                manual: "Paste a Cookie header from \(host).",
                off: "Alibaba Token Plan cookies are disabled.")
        }

        let regionBinding = Binding(
            get: { context.settings.alibabaTokenPlanAPIRegion.rawValue },
            set: { raw in
                context.settings.alibabaTokenPlanAPIRegion = AlibabaTokenPlanAPIRegion(rawValue: raw) ?? .international
            })
        let regionOptions = AlibabaTokenPlanAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "alibaba-token-plan-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies from Model Studio/Bailian.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(
                        provider: .alibabatokenplan,
                        scope: context.settings.alibabaTokenPlanAPIRegion.cookieCacheScope)
                }),
            ProviderSettingsPickerDescriptor(
                id: "alibaba-token-plan-region",
                title: "Gateway region",
                subtitle: "Use international or China mainland console gateways for quota fetches.",
                binding: regionBinding,
                options: regionOptions,
                isVisible: nil,
                onChange: nil),
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
                            NSWorkspace.shared.open(
                                AlibabaTokenPlanUsageFetcher.dashboardURL(
                                    region: context.settings.alibabaTokenPlanAPIRegion))
                        }),
                ],
                isVisible: {
                    context.settings.alibabaTokenPlanCookieSource == .manual
                },
                onActivate: nil),
        ]
    }
}
