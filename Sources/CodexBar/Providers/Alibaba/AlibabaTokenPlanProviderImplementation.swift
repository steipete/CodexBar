import AppKit
import CodexBarCore
import Foundation
import SwiftUI

/// Provider-specific by design: The Alibaba folder co-locates the distinct Alibaba Token Plan variant.
struct AlibabaTokenPlanProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .alibabatokenplan

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.alibabaTokenPlanUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.alibabaTokenPlanUsageDataSource
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.alibabaTokenPlanUsageDataSource
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
        let sourceBinding = Binding(
            get: { context.settings.alibabaTokenPlanUsageDataSource.rawValue },
            set: { raw in
                context.settings.alibabaTokenPlanUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let sourceOptions = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.cli.rawValue, title: "Bailian CLI"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]
        let cookieBinding = Binding(
            get: { context.settings.alibabaTokenPlanCookieSource.rawValue },
            set: { raw in
                context.settings.alibabaTokenPlanCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            let region = context.settings.alibabaTokenPlanAPIRegion
            let host = region.usesPersonalTokenPlanAPI
                ? URL(string: region.quotaBaseURLString)?.host
                : region.dashboardURL.host
            return ProviderCookieSourceUI.subtitle(
                source: context.settings.alibabaTokenPlanCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies from Model Studio/Bailian.",
                manual: "Paste a Cookie header from \(host ?? "the selected console").",
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
                id: "alibaba-token-plan-usage-source",
                title: "Usage source",
                subtitle: "Auto tries browser cookies, then the signed-in Bailian CLI.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.alibabaTokenPlanUsageDataSource == .auto else { return nil }
                    // Provider-specific by design: surface the active Auto fallback source for this provider.
                    let label = context.store.sourceLabel(for: .alibabatokenplan)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "alibaba-token-plan-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies from Model Studio/Bailian.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: {
                    context.settings.alibabaTokenPlanUsageDataSource == .auto
                        || context.settings.alibabaTokenPlanUsageDataSource == .web
                },
                onChange: nil,
                trailingText: {
                    // Provider-specific by design: This picker reads the co-located Token Plan variant's cache.
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
                    (context.settings.alibabaTokenPlanUsageDataSource == .auto
                        || context.settings.alibabaTokenPlanUsageDataSource == .web)
                        && context.settings.alibabaTokenPlanCookieSource == .manual
                },
                onActivate: nil),
        ]
    }
}
