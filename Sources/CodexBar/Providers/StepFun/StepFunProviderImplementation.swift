import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct StepFunProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .stepfun

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.stepfunCookieSource
        _ = settings.stepfunUsername
        _ = settings.stepfunPassword
        _ = settings.stepfunToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        // Available if any auth method is configured
        if !context.settings.stepfunUsername.isEmpty, !context.settings.stepfunPassword.isEmpty {
            return true
        }
        if context.settings.stepfunCookieSource == .manual, !context.settings.stepfunToken.isEmpty {
            return true
        }
        if CookieHeaderCache.load(provider: .stepfun) != nil {
            return true
        }
        if StepFunSettingsReader.username(environment: context.environment) != nil,
           StepFunSettingsReader.password(environment: context.environment) != nil
        {
            return true
        }
        if StepFunSettingsReader.token(environment: context.environment) != nil {
            return true
        }
        return false
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .stepfun(context.settings.stepfunSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.stepfunCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.stepfunCookieSource != .manual {
            settings.stepfunCookieSource = .manual
        }
    }

    // MARK: - Settings Pickers

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.stepfunCookieSource.rawValue },
            set: { raw in
                context.settings.stepfunCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.stepfunCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Uses username + password to login and obtain an Oasis-Token automatically.",
                manual: "Manually paste an Oasis-Token from a browser session.",
                off: "StepFun authentication is disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "stepfun-cookie-source",
                title: "Auth source",
                subtitle: "Uses username + password to login and obtain an Oasis-Token automatically.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .stepfun) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    // MARK: - Settings Fields

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        // Auto mode: show username + password fields
        let autoFields: [ProviderSettingsFieldDescriptor] = [
            ProviderSettingsFieldDescriptor(
                id: "stepfun-username",
                title: "Username",
                subtitle: "StepFun platform account (phone number or email).",
                kind: .plain,
                placeholder: "user@example.com",
                binding: context.stringBinding(\.stepfunUsername),
                actions: [],
                isVisible: { context.settings.stepfunCookieSource != .manual },
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "stepfun-password",
                title: "Password",
                subtitle: "Your StepFun platform password. Used to login and obtain a session token.",
                kind: .secure,
                placeholder: "Password",
                binding: context.stringBinding(\.stepfunPassword),
                actions: [],
                isVisible: { context.settings.stepfunCookieSource != .manual },
                onActivate: nil),
        ]

        // Manual mode: show token field
        let manualFields: [ProviderSettingsFieldDescriptor] = [
            ProviderSettingsFieldDescriptor(
                id: "stepfun-token",
                title: "Oasis-Token",
                subtitle: "Paste the Oasis-Token from a logged-in browser session on platform.stepfun.com.",
                kind: .secure,
                placeholder: "Oasis-Token=…",
                binding: context.stringBinding(\.stepfunToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "stepfun-open-platform",
                        title: "Open StepFun Platform",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.stepfun.com/plan-usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.stepfunCookieSource == .manual },
                onActivate: nil),
        ]

        return autoFields + manualFields
    }
}
