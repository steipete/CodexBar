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
        _ = settings.helmcodeDeploymentSelection
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .helmcode(context.settings.helmcodeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let deploymentBinding = Binding(
            get: { context.settings.helmcodeDeploymentSelection.rawValue },
            set: { raw in
                context.settings.helmcodeDeploymentSelection =
                    HelmcodeDeploymentSelection(rawValue: raw) ?? .auto
            })
        let deploymentOptions = HelmcodeDeploymentSelection.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let deploymentSubtitle: () -> String? = {
            guard context.settings.helmcodeDeploymentSelection == .auto else { return nil }
            guard let detected = context.settings.helmcodeDetectedDeployment else {
                return "Detected: no dashboard session yet; sign in to either dashboard in Chrome."
            }
            return "Detected: \(detected.sourceLabelName)"
        }
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
                auto: "Automatic imports Helmcode dashboard cookies from Chrome for the detected tenant.",
                manual: "Paste a Cookie header or cURL capture from the Helmcode dashboard.",
                off: "Helmcode dashboard cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "helmcode-deployment",
                title: "Deployment",
                subtitle: "Automatic detects the tenant from your session. Helmcode Cloud is the " +
                    "enterprise dashboard; NaN Builders is the community dashboard with the same usage APIs.",
                dynamicSubtitle: deploymentSubtitle,
                binding: deploymentBinding,
                options: deploymentOptions,
                isVisible: nil,
                onChange: nil),
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
                        title: "Open Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            let tenant = HelmcodeDeploymentResolver.dashboardDeployment(
                                settings: context.settings.helmcodeSettingsSnapshot(tokenOverride: nil),
                                environment: ProcessInfo.processInfo.environment)
                            NSWorkspace.shared.open(tenant.dashboardPageURL)
                        }),
                ],
                isVisible: { context.settings.helmcodeCookieSource == .manual },
                onActivate: { context.settings.ensureHelmcodeCookieLoaded() }),
        ]
    }
}
