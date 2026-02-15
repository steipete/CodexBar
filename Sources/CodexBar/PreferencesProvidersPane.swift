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

        let isAntigravity = provider == .antigravity

        let supportsTwoFieldEntry = isAntigravity
        let supportsManualEntry = true
        let addActionTitle = isAntigravity ? "Sign in with Google" : nil
        let addAction: (() async -> Void)? = isAntigravity
            ? {
                _ = await AntigravityLoginFlow.runOAuthFlow(
                    settings: self.settings,
                    store: self.store)
            }
            : nil
        let importAction: ProviderSettingsTokenAccountsDescriptor.ImportAction? = isAntigravity
            ? ProviderSettingsTokenAccountsDescriptor.ImportAction(
                title: "Import from Antigravity app",
                action: { await self.importAntigravityCredentials() })
            : nil

        return ProviderSettingsTokenAccountsDescriptor(
            id: "token-accounts-\(provider.rawValue)",
            title: support.title,
            subtitle: support.subtitle,
            placeholder: support.placeholder,
            supportsManualEntry: supportsManualEntry,
            supportsTwoFieldEntry: supportsTwoFieldEntry,
            addActionTitle: addActionTitle,
            addAction: addAction,
            importAction: importAction,
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
            addAccount: { label, token, token2 in
                if isAntigravity {
                    _ = self.settings.addManualAntigravityTokenAccount(
                        label: label,
                        accessToken: token,
                        refreshToken: token2.isEmpty ? nil : token2)
                } else {
                    self.settings.addTokenAccount(provider: provider, label: label, token: token)
                }
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(provider, allowDisabled: true)
                    }
                }
            },
            removeAccount: { accountID in
                if isAntigravity {
                    self.settings.removeAntigravityTokenAccount(accountID: accountID)
                } else {
                    self.settings.removeTokenAccount(provider: provider, accountID: accountID)
                }
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

    @MainActor
    private func importAntigravityCredentials() async {
        let log = CodexBarLog.logger(LogCategories.antigravity)
        log.debug("Starting credentials import from Antigravity DB")

        do {
            let credentials = try await AntigravityLocalImporter.importCredentials()
            log.debug(
                """
                Import successful - email: \(credentials.email ?? "none"), \
                hasAccessToken: \(credentials.hasAccessToken), hasRefreshToken: \(credentials.hasRefreshToken)
                """)

            guard let accessToken = credentials.accessToken, !accessToken.isEmpty else {
                log.debug("Import failed: no access token found")
                self.presentAlert(
                    title: "Import Failed",
                    message: "No access token found in Antigravity database.")
                return
            }

            let label = credentials.email ?? credentials.name ?? "Imported Account"
            log.debug("Creating manual token account with label: \(label)")

            guard let account = self.settings.addManualAntigravityTokenAccount(
                label: label,
                accessToken: accessToken,
                refreshToken: credentials.refreshToken,
                expiresAt: credentials.expiresAt)
            else {
                log.debug("Import failed: unable to save imported credentials")
                self.presentAlert(
                    title: "Import Failed",
                    message: "Unable to save imported credentials.")
                return
            }

            log.debug("Account created successfully: \(account.label)")
            await self.store.refreshProvider(.antigravity, allowDisabled: true)

            let alert = NSAlert()
            alert.messageText = "Import Successful"
            alert.informativeText = "Imported account: \(account.label)"
            alert.runModal()

        } catch let error as AntigravityOAuthCredentialsError {
            log.debug("Import failed with AntigravityOAuthCredentialsError: \(error)")
            switch error {
            case .permissionDenied:
                self.presentFullDiskAccessAlert()
            case .notFound:
                if AntigravityLocalImporter.isAvailable() {
                    self.presentAlert(
                        title: "No Credentials Found",
                        message: """
                        Antigravity database found, but no credentials were found inside.

                        Please ensure:
                        1. You are signed in to Antigravity IDE (check the Account menu)
                        2. Try restarting Antigravity IDE if you just signed in
                        3. If the issue persists, paste your tokens manually below
                        """)
                } else {
                    self.presentAlert(
                        title: "Import Failed",
                        message: "Antigravity database not found. Ensure Antigravity app is installed.")
                }
            default:
                self.presentAlert(
                    title: "Import Failed",
                    message: error.localizedDescription)
            }
        } catch {
            log.debug("Import failed with error: \(error)")
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == 1 || nsError.code == 13 {
                self.presentFullDiskAccessAlert()
            } else {
                self.presentAlert(
                    title: "Import Failed",
                    message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func presentFullDiskAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Full Disk Access Required"
        alert.informativeText =
            "Full Disk Access is required to read the Antigravity database. Please grant access in System Settings."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @MainActor
    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
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
        let metadata = self.store.metadata(for: provider)
        let supportsAverage = self.settings.menuBarMetricSupportsAverage(for: provider)
        var options: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: MenuBarMetricPreference.automatic.rawValue, title: "Automatic"),
            ProviderSettingsPickerOption(
                id: MenuBarMetricPreference.primary.rawValue,
                title: "Primary (\(metadata.sessionLabel))"),
            ProviderSettingsPickerOption(
                id: MenuBarMetricPreference.secondary.rawValue,
                title: "Secondary (\(metadata.weeklyLabel))"),
        ]
        if supportsAverage {
            options.append(ProviderSettingsPickerOption(
                id: MenuBarMetricPreference.average.rawValue,
                title: "Average (\(metadata.sessionLabel) + \(metadata.weeklyLabel))"))
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
        if provider == .codex {
            credits = self.store.credits
            creditsError = self.store.lastCreditsError
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
            hidePersonalInfo: self.settings.hidePersonalInfo,
            now: Date())
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
