import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct ProvidersPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var expandedErrors: Set<UsageProvider> = []
    @State private var settingsStatusTextByID: [String: String] = [:]
    @State private var settingsLastAppActiveRunAtByID: [String: Date] = [:]
    @State private var activeConfirmation: ProviderSettingsConfirmationState?
    @State private var selectedProvider: UsageProvider?

    private var providers: [UsageProvider] {
        self.settings.orderedProviders()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ProviderSidebarListView(
                providers: self.providers,
                store: self.store,
                isEnabled: { provider in self.binding(for: provider) },
                subtitle: { provider in self.providerSubtitle(provider) },
                selection: self.$selectedProvider,
                moveProviders: { fromOffsets, toOffset in
                    self.settings.moveProvider(fromOffsets: fromOffsets, toOffset: toOffset)
                })

            if let provider = self.selectedProvider ?? self.providers.first {
                ProviderDetailView(
                    provider: provider,
                    store: self.store,
                    settings: self.settings,
                    isEnabled: self.binding(for: provider),
                    subtitle: self.providerSubtitle(provider),
                    model: self.menuCardModel(for: provider),
                    settingsPickers: self.extraSettingsPickers(for: provider),
                    settingsToggles: self.extraSettingsToggles(for: provider),
                    settingsFields: self.extraSettingsFields(for: provider),
                    settingsTokenAccounts: self.tokenAccountDescriptor(for: provider),
                    errorDisplay: self.providerErrorDisplay(provider),
                    isErrorExpanded: self.expandedBinding(for: provider),
                    onCopyError: { text in self.copyToPasteboard(text) },
                    onRefresh: {
                        Task { @MainActor in
                            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                await self.store.refreshProvider(provider, allowDisabled: true)
                            }
                        }
                    })
            } else {
                Text("Select a provider")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear {
            self.ensureSelection()
        }
        .onChange(of: self.providers) { _, _ in
            self.ensureSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.runSettingsDidBecomeActiveHooks()
        }
        .alert(
            self.activeConfirmation?.title ?? "",
            isPresented: Binding(
                get: { self.activeConfirmation != nil },
                set: { isPresented in
                    if !isPresented { self.activeConfirmation = nil }
                }),
            actions: {
                if let active = self.activeConfirmation {
                    Button(active.confirmTitle) {
                        active.onConfirm()
                        self.activeConfirmation = nil
                    }
                    Button("Cancel", role: .cancel) { self.activeConfirmation = nil }
                }
            },
            message: {
                if let active = self.activeConfirmation {
                    Text(active.message)
                }
            })
    }

    private func ensureSelection() {
        guard !self.providers.isEmpty else {
            self.selectedProvider = nil
            return
        }
        if let selected = self.selectedProvider, self.providers.contains(selected) {
            return
        }
        self.selectedProvider = self.providers.first
    }

    func binding(for provider: UsageProvider) -> Binding<Bool> {
        let meta = self.store.metadata(for: provider)
        return Binding(
            get: { self.settings.isProviderEnabled(provider: provider, metadata: meta) },
            set: { newValue in
                self.settings.setProviderEnabled(provider: provider, metadata: meta, enabled: newValue)
            })
    }

    func providerSubtitle(_ provider: UsageProvider) -> String {
        let meta = self.store.metadata(for: provider)
        let usageText: String
        if let snapshot = self.store.snapshot(for: provider) {
            let relative = snapshot.updatedAt.relativeDescription()
            usageText = relative
        } else if self.store.isStale(provider: provider) {
            usageText = "last fetch failed"
        } else {
            usageText = "usage not fetched yet"
        }

        let presentationContext = ProviderPresentationContext(
            provider: provider,
            settings: self.settings,
            store: self.store,
            metadata: meta)
        let presentation = ProviderCatalog.implementation(for: provider)?
            .presentation(context: presentationContext)
            ?? ProviderPresentation(detailLine: ProviderPresentation.standardDetailLine)
        let detailLine = presentation.detailLine(presentationContext)

        return "\(detailLine)\n\(usageText)"
    }

    private func providerErrorDisplay(_ provider: UsageProvider) -> ProviderErrorDisplay? {
        guard let raw = self.store.error(for: provider), !raw.isEmpty else { return nil }
        return ProviderErrorDisplay(
            preview: self.truncated(raw, prefix: ""),
            full: raw)
    }

    private func extraSettingsToggles(for provider: UsageProvider) -> [ProviderSettingsToggleDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsToggles(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    private func extraSettingsPickers(for provider: UsageProvider) -> [ProviderSettingsPickerDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        let providerPickers = impl.settingsPickers(context: context)
            .filter { $0.isVisible?() ?? true }
        if let menuBarPicker = self.menuBarMetricPicker(for: provider) {
            return [menuBarPicker] + providerPickers
        }
        return providerPickers
    }

    private func extraSettingsFields(for provider: UsageProvider) -> [ProviderSettingsFieldDescriptor] {
        guard let impl = ProviderCatalog.implementation(for: provider) else { return [] }
        let context = self.makeSettingsContext(provider: provider)
        return impl.settingsFields(context: context)
            .filter { $0.isVisible?() ?? true }
    }

    func tokenAccountDescriptor(for provider: UsageProvider) -> ProviderSettingsTokenAccountsDescriptor? {
        guard let support = TokenAccountSupportCatalog.support(for: provider) else { return nil }
        let context = self.makeSettingsContext(provider: provider)
        let isSecureToken: Bool = {
            if case .codexHome = support.injection { return false }
            return true
        }()
        let impl = ProviderCatalog.implementation(for: provider)
        let loginAction = impl?.tokenAccountLoginAction(context: context)
        let defaultAccountLabel: (() -> String?)? = impl.map { imp in
            { imp.tokenAccountDefaultLabel(settings: self.settings) }
        }
        let renameDefaultAccount: ((_ newLabel: String) -> Void)? = impl.map { _ in
            { newLabel in self.settings.setDefaultAccountLabel(provider: provider, label: newLabel) }
        }
        let codexExplicit = provider == .codex && self.settings.codexExplicitAccountsOnly
        let accountsSubtitle: String = {
            if codexExplicit {
                return "Each row is its own sign-in: OAuth uses a separate credentials folder (CODEX_HOME), " +
                    "or use an API key. ~/.codex is not listed here while “CodexBar accounts only” is on."
            }
            return support.subtitle
        }()
        return ProviderSettingsTokenAccountsDescriptor(
            id: "token-accounts-\(provider.rawValue)",
            title: support.title,
            subtitle: accountsSubtitle,
            placeholder: support.placeholder,
            isSecureToken: isSecureToken,
            provider: provider,
            isVisible: {
                ProviderCatalog.implementation(for: provider)?
                    .tokenAccountsVisibility(context: context, support: support)
                    ?? (!support.requiresManualCookieSource ||
                        !context.settings.tokenAccounts(for: provider).isEmpty)
            },
            accounts: { self.settings.tokenAccounts(for: provider) },
            activeIndex: {
                guard let data = self.settings.tokenAccountsData(for: provider) else { return -1 }
                return data.activeIndex
            },
            setActiveIndex: { index in
                self.settings.setActiveTokenAccountIndex(index, for: provider)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            addAccount: { label, token in
                self.settings.addTokenAccount(provider: provider, label: label, token: token)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            removeAccount: { accountID in
                self.settings.removeTokenAccount(provider: provider, accountID: accountID)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            moveAccount: { fromOffsets, toOffset in
                self.settings.moveTokenAccount(provider: provider, fromOffsets: fromOffsets, toOffset: toOffset)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            renameAccount: { accountID, newLabel in
                self.settings.renameTokenAccount(provider: provider, accountID: accountID, newLabel: newLabel)
            },
            openConfigFile: {
                self.settings.openTokenAccountsFile()
            },
            reloadFromDisk: {
                self.settings.reloadTokenAccounts()
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            defaultAccountLabel: defaultAccountLabel,
            renameDefaultAccount: renameDefaultAccount,
            loginAction: loginAction,
            codexExplicitAccountsOnly: codexExplicit)
    }

    private func makeSettingsContext(provider: UsageProvider) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: provider,
            settings: self.settings,
            store: self.store,
            boolBinding: { keyPath in
                Binding(
                    get: { self.settings[keyPath: keyPath] },
                    set: { self.settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { self.settings[keyPath: keyPath] },
                    set: { self.settings[keyPath: keyPath] = $0 })
            },
            statusText: { id in
                self.settingsStatusTextByID[id]
            },
            setStatusText: { id, text in
                if let text {
                    self.settingsStatusTextByID[id] = text
                } else {
                    self.settingsStatusTextByID.removeValue(forKey: id)
                }
            },
            lastAppActiveRunAt: { id in
                self.settingsLastAppActiveRunAtByID[id]
            },
            setLastAppActiveRunAt: { id, date in
                if let date {
                    self.settingsLastAppActiveRunAtByID[id] = date
                } else {
                    self.settingsLastAppActiveRunAtByID.removeValue(forKey: id)
                }
            },
            requestConfirmation: { confirmation in
                self.activeConfirmation = ProviderSettingsConfirmationState(confirmation: confirmation)
            })
    }

    func menuBarMetricPicker(for provider: UsageProvider) -> ProviderSettingsPickerDescriptor? {
        if provider == .zai { return nil }
        let options: [ProviderSettingsPickerOption]
        if provider == .openrouter {
            options = [
                ProviderSettingsPickerOption(id: MenuBarMetricPreference.automatic.rawValue, title: "Automatic"),
                ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.primary.rawValue,
                    title: "Primary (API key limit)"),
            ]
        } else {
            let metadata = self.store.metadata(for: provider)
            let supportsAverage = self.settings.menuBarMetricSupportsAverage(for: provider)
            var metricOptions: [ProviderSettingsPickerOption] = [
                ProviderSettingsPickerOption(id: MenuBarMetricPreference.automatic.rawValue, title: "Automatic"),
                ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.primary.rawValue,
                    title: "Primary (\(metadata.sessionLabel))"),
                ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.secondary.rawValue,
                    title: "Secondary (\(metadata.weeklyLabel))"),
            ]
            if supportsAverage {
                metricOptions.append(ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.average.rawValue,
                    title: "Average (\(metadata.sessionLabel) + \(metadata.weeklyLabel))"))
            }
            options = metricOptions
        }
        return ProviderSettingsPickerDescriptor(
            id: "menuBarMetric",
            title: "Menu bar metric",
            subtitle: "Choose which window drives the menu bar percent.",
            binding: Binding(
                get: { self.settings.menuBarMetricPreference(for: provider).rawValue },
                set: { rawValue in
                    guard let preference = MenuBarMetricPreference(rawValue: rawValue) else { return }
                    self.settings.setMenuBarMetricPreference(preference, for: provider)
                }),
            options: options,
            isVisible: { true },
            onChange: nil)
    }

    func menuCardModel(for provider: UsageProvider) -> UsageMenuCardView.Model {
        let metadata = self.store.metadata(for: provider)
        let snapshot = self.store.snapshot(for: provider)
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        var codexCreditsUnlimited = false
        if provider == .codex {
            let active = self.store.codexActiveMenuCredits()
            credits = active.snapshot
            creditsError = active.error
            codexCreditsUnlimited = active.unlimited
            dashboard = self.store.openAIDashboardRequiresLogin ? nil : self.store.openAIDashboard
            dashboardError = self.store.lastOpenAIDashboardError
            tokenSnapshot = self.store.tokenSnapshot(for: provider)
            tokenError = self.store.tokenError(for: provider)
        } else if provider == .claude || provider == .vertexai {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = self.store.tokenSnapshot(for: provider)
            tokenError = self.store.tokenError(for: provider)
        } else {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = nil
            tokenError = nil
        }

        let now = Date()
        let weeklyPace = snapshot?.secondary.flatMap { window in
            self.store.weeklyPace(provider: provider, window: window, now: now)
        }
        let input = UsageMenuCardView.Model.Input(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            credits: credits,
            creditsError: creditsError,
            dashboard: dashboard,
            dashboardError: dashboardError,
            tokenSnapshot: tokenSnapshot,
            tokenError: tokenError,
            account: self.store.accountInfo(),
            isRefreshing: self.store.refreshingProviders.contains(provider),
            lastError: self.store.error(for: provider),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            tokenCostUsageEnabled: self.settings.isCostUsageEffectivelyEnabled(for: provider),
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage,
            codexCreditsUnlimited: codexCreditsUnlimited,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            weeklyPace: weeklyPace,
            now: now)
        return UsageMenuCardView.Model.make(input)
    }

    private func runSettingsDidBecomeActiveHooks() {
        for provider in UsageProvider.allCases {
            for toggle in self.extraSettingsToggles(for: provider) {
                guard let hook = toggle.onAppDidBecomeActive else { continue }
                Task { @MainActor in
                    await hook()
                }
            }
        }
    }

    private func truncated(_ text: String, prefix: String, maxLength: Int = 160) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > maxLength {
            let idx = message.index(message.startIndex, offsetBy: maxLength)
            message = "\(message[..<idx])…"
        }
        return prefix + message
    }

    private func expandedBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.expandedErrors.contains(provider) },
            set: { expanded in
                if expanded {
                    self.expandedErrors.insert(provider)
                } else {
                    self.expandedErrors.remove(provider)
                }
            })
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

@MainActor
struct ProviderSettingsConfirmationState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void

    init(confirmation: ProviderSettingsConfirmation) {
        self.title = confirmation.title
        self.message = confirmation.message
        self.confirmTitle = confirmation.confirmTitle
        self.onConfirm = confirmation.onConfirm
    }
}
