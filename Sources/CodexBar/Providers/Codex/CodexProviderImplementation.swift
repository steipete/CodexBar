import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct CodexProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .codex
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.version(for: context.provider) ?? "not detected"
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.codexUsageDataSource
        _ = settings.codexCookieSource
        _ = settings.codexCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .codex(context.settings.codexSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.codexUsageDataSource.rawValue
    }

    @MainActor
    func decorateSourceLabel(context: ProviderSourceLabelContext, baseLabel: String) -> String {
        if context.settings.codexCookieSource.isEnabled,
           context.store.openAIDashboard != nil,
           !context.store.openAIDashboardRequiresLogin,
           !baseLabel.contains("openai-web")
        {
            return "\(baseLabel) + openai-web"
        }
        return baseLabel
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.codexUsageDataSource {
        case .auto: .auto
        case .oauth: .oauth
        case .cli: .cli
        }
    }

    func makeRuntime() -> (any ProviderRuntime)? {
        CodexProviderRuntime()
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        let extrasBinding = Binding(
            get: { context.settings.openAIWebAccessEnabled },
            set: { enabled in
                context.settings.openAIWebAccessEnabled = enabled
                Task { @MainActor in
                    await context.store.performRuntimeAction(
                        .openAIWebAccessToggled(enabled),
                        for: .codex)
                }
            })

        let buyCreditsBinding = Binding(
            get: { context.settings.codexBuyCreditsMenuEnabled },
            set: { context.settings.codexBuyCreditsMenuEnabled = $0 })

        return [
            ProviderSettingsToggleDescriptor(
                id: "codex-buy-credits-menu",
                title: "Show Buy Credits in menu",
                subtitle: "Adds a “Buy Credits…” item to the Codex menu for ChatGPT billing.",
                binding: buyCreditsBinding,
                statusText: {
                    guard context.settings.codexBuyCreditsMenuEnabled else { return nil }
                    let hasKey = !(context.settings.providerConfig(for: .codex)?.sanitizedAPIKey ?? "").isEmpty
                    if !hasKey {
                        return "No API key saved — only OAuth / browser-based flows are configured for Codex."
                    }
                    return nil
                },
                actions: [],
                isVisible: nil,
                onChange: { enabled in
                    guard enabled else { return }
                    let hasKey = !(context.settings.providerConfig(for: .codex)?.sanitizedAPIKey ?? "").isEmpty
                    guard !hasKey else { return }
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "No API key configured"
                        alert.informativeText =
                            "Buy Credits opens the ChatGPT billing page. You don’t have an API key saved for Codex — only OAuth-based usage is configured. You can still continue; add an API key in Codex settings if you use one."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                },
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-historical-tracking",
                title: "Historical tracking",
                subtitle: "Stores local Codex usage history (8 weeks) to personalize Pace predictions.",
                binding: context.boolBinding(\.historicalTrackingEnabled),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "codex-openai-web-extras",
                title: "OpenAI web extras",
                subtitle: "Show usage breakdown, credits history, and code review via chatgpt.com.",
                binding: extrasBinding,
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.codexUsageDataSource.rawValue },
            set: { raw in
                context.settings.codexUsageDataSource = CodexUsageDataSource(rawValue: raw) ?? .auto
            })
        let cookieBinding = Binding(
            get: { context.settings.codexCookieSource.rawValue },
            set: { raw in
                context.settings.codexCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })

        let menuBarAccountBinding = Binding(
            get: {
                let accounts = context.settings.tokenAccounts(for: .codex)
                let hasPrimary = self.tokenAccountDefaultLabel(settings: context.settings) != nil
                let raw = context.settings.tokenAccountsData(for: .codex)?.activeIndex ?? -1
                if hasPrimary, raw < 0 { return "default" }
                guard !accounts.isEmpty else { return hasPrimary ? "default" : "0" }
                let idx = min(max(raw < 0 ? 0 : raw, 0), accounts.count - 1)
                return String(idx)
            },
            set: { newId in
                if newId == "default" {
                    context.settings.setActiveTokenAccountIndex(-1, for: .codex)
                } else if let idx = Int(newId) {
                    context.settings.setActiveTokenAccountIndex(idx, for: .codex)
                }
            })

        var menuBarAccountOptions: [ProviderSettingsPickerOption] = []
        if self.tokenAccountDefaultLabel(settings: context.settings) != nil {
            let custom = context.settings.providerConfig(for: .codex)?.defaultAccountLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let custom, !custom.isEmpty {
                title = custom
            } else if let email = self.tokenAccountDefaultLabel(settings: context.settings) {
                title = email
            } else {
                title = "Primary"
            }
            menuBarAccountOptions.append(
                ProviderSettingsPickerOption(
                    id: "default",
                    title: "\(title) (primary ~/.codex)"))
        }
        for (i, acc) in context.settings.tokenAccounts(for: .codex).enumerated() {
            menuBarAccountOptions.append(ProviderSettingsPickerOption(id: String(i), title: acc.displayName))
        }

        let usageOptions = CodexUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.codexCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies for dashboard extras.",
                manual: "Paste a Cookie header from a chatgpt.com request.",
                off: "Disable OpenAI dashboard cookie usage.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "codex-menu-bar-account",
                title: "Menu bar account",
                subtitle: "Which Codex account drives the menu bar and usage on this Mac.",
                binding: menuBarAccountBinding,
                options: menuBarAccountOptions,
                isVisible: {
                    let accounts = context.settings.tokenAccounts(for: .codex)
                    let hasPrimary = self.tokenAccountDefaultLabel(settings: context.settings) != nil
                    return (hasPrimary ? 1 : 0) + accounts.count >= 2
                },
                onChange: { _ in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await context.store.refreshProvider(.codex, allowDisabled: true)
                    }
                },
                section: .options),
            ProviderSettingsPickerDescriptor(
                id: "codex-usage-source",
                title: "Usage source",
                subtitle: "Auto falls back to the next source if the preferred one fails.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.codexUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .codex)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "codex-cookie-source",
                title: "OpenAI cookies",
                subtitle: "Automatic imports browser cookies for dashboard extras.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: { context.settings.openAIWebAccessEnabled },
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .codex) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "codex-cookie-header",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.codexCookieHeader),
                actions: [],
                isVisible: {
                    context.settings.codexCookieSource == .manual
                },
                onActivate: { context.settings.ensureCodexCookieLoaded() }),
        ]
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard context.settings.showOptionalCreditsAndExtraUsage,
              context.metadata.supportsCredits
        else { return }

        let active = context.store.codexActiveMenuCredits()
        if let credits = active.snapshot, credits.remaining.isFinite, credits.remaining > 0 {
            entries.append(.text("Credits: \(UsageFormatter.creditsString(from: credits.remaining))", .primary))
            if let latest = credits.events.first {
                entries.append(.text("Last spend: \(UsageFormatter.creditEventSummary(latest))", .secondary))
            }
        } else if active.unlimited {
            entries.append(.text("Credits: Unlimited", .primary))
        } else if let err = active.error, !err.isEmpty {
            entries.append(.text(err, .secondary))
        } else {
            let hint = context.store.lastCreditsError ?? context.metadata.creditsHint
            entries.append(.text(hint, .secondary))
        }
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        ("Add Account...", .addTokenAccount(.codex))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runCodexLoginFlow()
        return true
    }

    @MainActor
    func tokenAccountDefaultLabel(settings: SettingsStore?) -> String? {
        if let custom = settings?.providerConfig(for: .codex)?.defaultAccountLabel,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return custom
        }
        guard let credentials = try? CodexOAuthCredentialsStore.load() else { return nil }

        if let idToken = credentials.idToken,
           let payload = UsageFetcher.parseJWT(idToken)
        {
            let profileDict = payload["https://api.openai.com/profile"] as? [String: Any]
            let email = (payload["email"] as? String) ?? (profileDict?["email"] as? String)
            let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }

        // API-key auth (`auth.json` with OPENAI_API_KEY): valid credentials but no id_token/JWT.
        let access = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !access.isEmpty, refresh.isEmpty {
            return "API key"
        }

        // OAuth loaded but no usable email/id_token (unusual); still treat default account as present.
        if !refresh.isEmpty {
            return "Codex"
        }

        return nil
    }

    @MainActor
    func tokenAccountLoginAction(context _: ProviderSettingsContext)
        -> ((
            _ setProgress: @escaping @MainActor (String) -> Void,
            _ addAccount: @escaping @MainActor (String, String) -> Void
        ) async -> Bool)?
    {
        return { @MainActor setProgress, addAccount in
            let accountsDir = (("~/.codex-accounts") as NSString).expandingTildeInPath
            let uniqueDir = "\(accountsDir)/\(UUID().uuidString.prefix(8))"
            try? FileManager.default.createDirectory(
                atPath: uniqueDir,
                withIntermediateDirectories: true)

            setProgress("Opening browser for login…")
            let result = await CodexLoginRunner.run(codexHome: uniqueDir, timeout: 180)

            switch result.outcome {
            case .success:
                setProgress("Signed in — reading account info…")
                let env = ["CODEX_HOME": uniqueDir]
                let label: String
                if let credentials = try? CodexOAuthCredentialsStore.load(env: env),
                   let idToken = credentials.idToken,
                   let payload = UsageFetcher.parseJWT(idToken)
                {
                    let profileDict = payload["https://api.openai.com/profile"] as? [String: Any]
                    let email = (payload["email"] as? String) ?? (profileDict?["email"] as? String)
                    label = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Account"
                } else {
                    label = "Account"
                }
                addAccount(label, uniqueDir)
                return true

            case .missingBinary, .timedOut, .failed, .launchFailed:
                try? FileManager.default.removeItem(atPath: uniqueDir)
                return false
            }
        }
    }
}
