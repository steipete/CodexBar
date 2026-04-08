import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct ProvidersPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let codexAmbientLoginRunner: any CodexAmbientLoginRunning
    @State private var expandedErrors: Set<UsageProvider> = []
    @State private var settingsStatusTextByID: [String: String] = [:]
    @State private var settingsLastAppActiveRunAtByID: [String: Date] = [:]
    @State private var activeConfirmation: ProviderSettingsConfirmationState?
    @State private var codexAccountsNotice: CodexAccountsSectionNotice?
    @State private var isAuthenticatingLiveCodexAccount = false
    @State private var selectedProvider: UsageProvider?

    private var providers: [UsageProvider] {
        self.settings.orderedProviders()
    }

    init(
        settings: SettingsStore,
        store: UsageStore,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator(),
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        codexAmbientLoginRunner: any CodexAmbientLoginRunning = DefaultCodexAmbientLoginRunner())
    {
        self.settings = settings
        self.store = store
        self.managedCodexAccountCoordinator = managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = codexAccountPromotionCoordinator
            ?? CodexAccountPromotionCoordinator(
                settingsStore: settings,
                usageStore: store,
                managedAccountCoordinator: managedCodexAccountCoordinator)
        self.codexAmbientLoginRunner = codexAmbientLoginRunner
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
                                if provider == .codex {
                                    await self.store.refreshCodexAccountScopedState(allowDisabled: true)
                                } else {
                                    await self.store.refreshProvider(provider, allowDisabled: true)
                                }
                            }
                        }
                    },
                    showsSupplementarySettingsContent: self.codexAccountsSectionState(for: provider) != nil,
                    supplementarySettingsContent: {
                        if let state = self.codexAccountsSectionState(for: provider) {
                            CodexAccountsSectionView(
                                state: state,
                                setActiveVisibleAccount: { visibleAccountID in
                                    Task { @MainActor in
                                        await self.selectCodexVisibleAccount(id: visibleAccountID)
                                    }
                                },
                                reauthenticateAccount: { account in
                                    Task { @MainActor in
                                        await self.reauthenticateCodexAccount(account)
                                    }
                                },
                                removeAccount: { account in
                                    self.requestManagedCodexAccountRemoval(account)
                                },
                                requestSystemVisibleAccount: { visibleAccountID in
                                    Task { @MainActor in
                                        await self.requestCodexSystemVisibleAccount(id: visibleAccountID)
                                    }
                                },
                                addAccount: {
                                    Task { @MainActor in
                                        await self.addManagedCodexAccount()
                                    }
                                })
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

    func codexAccountsSectionState(for provider: UsageProvider) -> CodexAccountsSectionState? {
        guard provider == .codex else { return nil }
        let projection = self.settings.codexVisibleAccountProjection
        let degradedNotice: CodexAccountsSectionNotice? = if projection.hasUnreadableAddedAccountStore {
            CodexAccountsSectionNotice(
                text: "Managed account storage is unreadable. Live account access is still available, "
                    + "but managed add, re-auth, and remove actions are disabled until the store is recoverable.",
                tone: .warning)
        } else {
            nil
        }

        return CodexAccountsSectionState(
            visibleAccounts: projection.visibleAccounts,
            activeVisibleAccountID: projection.activeVisibleAccountID,
            liveVisibleAccountID: projection.liveVisibleAccountID,
            hasUnreadableManagedAccountStore: projection.hasUnreadableAddedAccountStore,
            isAuthenticatingManagedAccount: self.managedCodexAccountCoordinator.isAuthenticatingManagedAccount,
            authenticatingManagedAccountID: self.managedCodexAccountCoordinator.authenticatingManagedAccountID,
            isRemovingManagedAccount: self.managedCodexAccountCoordinator.isRemovingManagedAccount,
            isAuthenticatingLiveAccount: self.isAuthenticatingLiveCodexAccount,
            isPromotingSystemAccount: self.codexAccountPromotionCoordinator.isPromotingSystemAccount,
            notice: self.codexAccountsNotice ?? degradedNotice)
    }

    func selectCodexVisibleAccount(id: String) async {
        self.codexAccountsNotice = nil
        guard self.settings.selectCodexVisibleAccount(id: id) else { return }
        await self.refreshCodexProvider()
    }

    func requestCodexSystemVisibleAccount(id: String) async {
        self.codexAccountsNotice = nil
        guard let account = self.settings.codexVisibleAccountProjection.visibleAccounts.first(where: { $0.id == id }),
              let managedAccountID = account.storedAccountID
        else {
            return
        }

        let result = await self.codexAccountPromotionCoordinator.promote(managedAccountID: managedAccountID)
        if case let .failure(error) = result {
            self.codexAccountsNotice = CodexAccountsSectionNotice(text: error.message, tone: .warning)
        }
    }

    func addManagedCodexAccount() async {
        self.codexAccountsNotice = nil
        guard let state = self.codexAccountsSectionState(for: .codex), state.canAddAccount else {
            return
        }

        do {
            let account = try await self.managedCodexAccountCoordinator.authenticateManagedAccount()
            self.selectCodexVisibleAccountForAuthenticatedManagedAccount(account)
            await self.refreshCodexProvider()
        } catch {
            self.codexAccountsNotice = self.codexAccountsNotice(for: error)
        }
    }

    func reauthenticateCodexAccount(_ account: CodexVisibleAccount) async {
        self.codexAccountsNotice = nil
        if let accountID = account.storedAccountID {
            guard let state = self.codexAccountsSectionState(for: .codex), state.canReauthenticate(account) else {
                return
            }
            do {
                _ = try await self.managedCodexAccountCoordinator
                    .authenticateManagedAccount(existingAccountID: accountID)
                await self.refreshCodexProvider()
            } catch {
                self.codexAccountsNotice = self.codexAccountsNotice(for: error)
            }
            return
        }

        guard let state = self.codexAccountsSectionState(for: .codex), state.canReauthenticate(account) else {
            return
        }

        self.isAuthenticatingLiveCodexAccount = true
        self.codexAccountPromotionCoordinator.setLiveReauthenticationInProgress(true)
        defer {
            self.isAuthenticatingLiveCodexAccount = false
            self.codexAccountPromotionCoordinator.setLiveReauthenticationInProgress(false)
        }

        let result = await self.codexAmbientLoginRunner.run(timeout: 120)
        if let info = CodexLoginAlertPresentation.alertInfo(for: result) {
            self.presentLoginAlert(title: info.title, message: info.message)
            return
        }

        await self.refreshCodexProvider()
    }

    func removeManagedCodexAccount(id: UUID) async {
        self.codexAccountsNotice = nil
        do {
            try await self.managedCodexAccountCoordinator.removeManagedAccount(id: id)
            await self.refreshCodexProvider()
        } catch {
            self.codexAccountsNotice = self.codexAccountsNotice(for: error)
        }
    }

    func requestManagedCodexAccountRemoval(_ account: CodexVisibleAccount) {
        guard let accountID = account.storedAccountID else { return }
        self.activeConfirmation = ProviderSettingsConfirmationState(
            title: "Remove Codex account?",
            message: "Remove \(account.email) from CodexBar? Its managed Codex home will be deleted.",
            confirmTitle: "Remove",
            onConfirm: {
                Task { @MainActor in
                    await self.removeManagedCodexAccount(id: accountID)
                }
            })
    }

    func providerErrorDisplay(_ provider: UsageProvider) -> ProviderErrorDisplay? {
        guard let full = self.store.error(for: provider), !full.isEmpty else { return nil }
        let preview = self.store.userFacingError(for: provider) ?? full
        return ProviderErrorDisplay(
            preview: self.truncated(preview, prefix: ""),
            full: full)
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
        return ProviderSettingsTokenAccountsDescriptor(
            id: "token-accounts-\(provider.rawValue)",
            title: support.title,
            subtitle: support.subtitle,
            placeholder: support.placeholder,
            provider: provider,
            isVisible: {
                ProviderCatalog.implementation(for: provider)?
                    .tokenAccountsVisibility(context: context, support: support)
                    ?? (!support.requiresManualCookieSource ||
                        !context.settings.tokenAccounts(for: provider).isEmpty)
            },
            accounts: { self.settings.tokenAccounts(for: provider) },
            activeIndex: {
                let data = self.settings.tokenAccountsData(for: provider)
                return data?.clampedActiveIndex() ?? 0
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
            })
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
            let snapshot = self.store.snapshot(for: provider)
            let supportsAverage = self.settings.menuBarMetricSupportsAverage(for: provider)
            let supportsTertiary = self.settings.menuBarMetricSupportsTertiary(for: provider, snapshot: snapshot)
            var metricOptions: [ProviderSettingsPickerOption] = [
                ProviderSettingsPickerOption(id: MenuBarMetricPreference.automatic.rawValue, title: "Automatic"),
                ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.primary.rawValue,
                    title: "Primary (\(metadata.sessionLabel))"),
                ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.secondary.rawValue,
                    title: "Secondary (\(metadata.weeklyLabel))"),
            ]
            if supportsTertiary {
                let tertiaryTitle = metadata.opusLabel ?? MenuBarMetricPreference.tertiary.label
                metricOptions.append(ProviderSettingsPickerOption(
                    id: MenuBarMetricPreference.tertiary.rawValue,
                    title: "Tertiary (\(tertiaryTitle))"))
            }
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
                get: {
                    self.settings
                        .menuBarMetricPreference(for: provider, snapshot: self.store.snapshot(for: provider))
                        .rawValue
                },
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
        let now = Date()
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .liveCard,
            now: now)
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        if let codexProjection {
            credits = codexProjection.credits?.snapshot
            creditsError = codexProjection.credits?.userFacingError
            dashboard = nil
            dashboardError = codexProjection.userFacingErrors.dashboard
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

        let weeklyPace = if let codexProjection,
                            let weekly = codexProjection.rateWindow(for: .weekly)
        {
            self.store.weeklyPace(provider: provider, window: weekly, now: now)
        } else {
            snapshot?.secondary.flatMap { window in
                self.store.weeklyPace(provider: provider, window: window, now: now)
            }
        }
        let input = UsageMenuCardView.Model.Input(
            provider: provider,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: credits,
            creditsError: creditsError,
            dashboard: dashboard,
            dashboardError: dashboardError,
            tokenSnapshot: tokenSnapshot,
            tokenError: tokenError,
            account: self.store.accountInfo(for: provider),
            isRefreshing: self.store.refreshingProviders.contains(provider),
            lastError: codexProjection?.userFacingErrors.usage ?? self.store.userFacingError(for: provider),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            tokenCostUsageEnabled: self.settings.isCostUsageEffectivelyEnabled(for: provider),
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage,
            hidePersonalInfo: self.settings.hidePersonalInfo,
            weeklyPace: weeklyPace,
            now: now)
        return UsageMenuCardView.Model.make(input)
    }

    private func refreshCodexProvider() async {
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await self.store.refreshCodexAccountScopedState(allowDisabled: true)
        }
    }

    private func selectCodexVisibleAccountForAuthenticatedManagedAccount(_ account: ManagedCodexAccount) {
        self.settings.selectAuthenticatedManagedCodexAccount(account)
    }

    private func codexAccountsNotice(for error: Error) -> CodexAccountsSectionNotice {
        if let error = error as? ManagedCodexAccountCoordinatorError,
           error == .authenticationInProgress
        {
            return CodexAccountsSectionNotice(
                text: "A managed Codex login is already running. Wait for it to finish before adding "
                    + "or re-authenticating another account.",
                tone: .warning)
        }

        if let error = error as? ManagedCodexAccountServiceError {
            let message = switch error {
            case .loginFailed:
                "Managed Codex login did not complete. Try again after finishing the browser login flow."
            case .missingEmail:
                "Codex login completed, but no account email was available. Try again after confirming "
                    + "the account is fully signed in."
            case let .unsafeManagedHome(path):
                "CodexBar refused to modify an unexpected managed home path: \(path)"
            }
            return CodexAccountsSectionNotice(text: message, tone: .warning)
        }

        return CodexAccountsSectionNotice(
            text: error.localizedDescription,
            tone: .warning)
    }

    private func presentLoginAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
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

    init(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void)
    {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
    }

    init(confirmation: ProviderSettingsConfirmation) {
        self.title = confirmation.title
        self.message = confirmation.message
        self.confirmTitle = confirmation.confirmTitle
        self.onConfirm = confirmation.onConfirm
    }
}
