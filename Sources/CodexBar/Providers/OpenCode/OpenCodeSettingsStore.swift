import CodexBarCore
import Foundation

extension SettingsStore {
    var opencodeWorkspaceAccounts: OpenCodeWorkspaceAccounts {
        get {
            self.configSnapshot.providerConfig(for: .opencode)?.opencodeWorkspaceAccounts
                ?? OpenCodeWorkspaceAccounts()
        }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.opencodeWorkspaceAccounts = newValue
                entry.opencodeActiveWorkspaceAccountID = newValue.activeID
            }
        }
    }

    var activeOpenCodeWorkspaceAccount: OpenCodeWorkspaceAccount? {
        self.opencodeWorkspaceAccounts.active
    }

    @discardableResult
    func setActiveOpenCodeWorkspace(id: String) -> Bool {
        var accounts = self.opencodeWorkspaceAccounts
        guard accounts.selectActive(id: id) else { return false }
        self.opencodeWorkspaceAccounts = accounts
        return true
    }

    @discardableResult
    func addOpenCodeWorkspace(
        tokenAccountID: UUID?,
        workspaceID: String?,
        label: String,
        ownerLabel: String? = nil,
        now: Date = Date()) -> OpenCodeWorkspaceAccountMutationResult
    {
        var accounts = self.opencodeWorkspaceAccounts
        let result = accounts.add(
            tokenAccountID: tokenAccountID,
            workspaceID: workspaceID,
            label: label,
            ownerLabel: ownerLabel,
            now: now)
        if result == .saved {
            self.opencodeWorkspaceAccounts = accounts
        }
        return result
    }

    func removeOpenCodeWorkspace(id: String) {
        var accounts = self.opencodeWorkspaceAccounts
        guard accounts.remove(id: id) else { return }
        self.opencodeWorkspaceAccounts = accounts
    }

    func pruneOpenCodeWorkspaces() {
        var accounts = self.opencodeWorkspaceAccounts
        accounts.prune(validTokenAccountIDs: Set(self.tokenAccounts(for: .opencode).map(\.id)))
        self.opencodeWorkspaceAccounts = accounts
    }

    @discardableResult
    func syncOpenCodeWorkspaceSelectionFromAppGroup() -> Bool {
        guard let defaults = AppGroupSupport.sharedDefaults(),
              let selectedID = defaults.string(forKey: Self.openCodeWidgetSelectionKey)
        else {
            return false
        }
        var accounts = self.opencodeWorkspaceAccounts
        guard accounts.selectActive(id: selectedID) else {
            defaults.removeObject(forKey: Self.openCodeWidgetSelectionKey)
            return false
        }
        guard accounts.activeID != self.opencodeWorkspaceAccounts.activeID else { return false }
        self.opencodeWorkspaceAccounts = accounts
        return true
    }

    var opencodeWorkspaceID: String {
        get { self.configSnapshot.providerConfig(for: .opencode)?.workspaceID ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.workspaceID = value
            }
        }
    }

    var opencodeCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .opencode)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .opencode, field: "cookieHeader", value: newValue)
        }
    }

    var opencodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .opencode, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .opencode, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureOpenCodeCookieLoaded() {}
}

extension SettingsStore {
    func opencodeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .OpenCodeProviderSettings {
        let workspaceAccount = self.resolvedOpenCodeWorkspaceAccount
        return ProviderSettingsSnapshot.OpenCodeProviderSettings(
            cookieSource: self.opencodeSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.opencodeSnapshotCookieHeader(tokenOverride: tokenOverride),
            workspaceID: workspaceAccount?.workspaceID ?? self.opencodeWorkspaceID,
            workspaceAccountID: workspaceAccount?.id)
    }

    private func opencodeSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.opencodeCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .opencode),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = self.selectedOpenCodeTokenAccount(tokenOverride: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func opencodeSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.opencodeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .opencode),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .opencode).isEmpty { return fallback }
        return .manual
    }

    private var resolvedOpenCodeWorkspaceAccount: OpenCodeWorkspaceAccount? {
        if let active = self.activeOpenCodeWorkspaceAccount {
            return active
        }
        guard self.opencodeWorkspaceAccounts.accounts.isEmpty,
              let workspaceID = OpenCodeWorkspaceAccount.normalizeWorkspaceID(self.opencodeWorkspaceID),
              let tokenAccount = self.settingsTokenAccountForOpenCode
        else {
            return nil
        }
        return OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccount.id,
            workspaceID: workspaceID,
            label: tokenAccount.label)
    }

    private var settingsTokenAccountForOpenCode: ProviderTokenAccount? {
        self.selectedTokenAccount(for: .opencode)
    }

    private func selectedOpenCodeTokenAccount(tokenOverride: TokenAccountOverride?) -> ProviderTokenAccount? {
        if let tokenOverride {
            return tokenOverride.account
        }
        if let workspaceAccount = self.resolvedOpenCodeWorkspaceAccount,
           let account = self.tokenAccounts(for: .opencode)
            .first(where: { $0.id == workspaceAccount.tokenAccountID })
        {
            return account
        }
        return self.settingsTokenAccountForOpenCode
    }
}

extension SettingsStore {
    static let openCodeWidgetSelectionKey = "widget.selectedOpenCodeWorkspaceAccountID"

    func saveOpenCodeWorkspaces(
        _ workspaces: [OpenCodeDiscoveredWorkspace],
        tokenAccountID: UUID,
        now: Date = Date()) -> [OpenCodeWorkspaceAccountMutationResult]
    {
        var accounts = self.opencodeWorkspaceAccounts
        let results = workspaces.map { workspace in
            accounts.add(
                tokenAccountID: tokenAccountID,
                workspaceID: workspace.workspaceID,
                label: workspace.label,
                ownerLabel: workspace.ownerLabel,
                now: now)
        }
        self.opencodeWorkspaceAccounts = accounts
        return results
    }

    func importOpenCodeWorkspaceAccounts(
        browserDetection: BrowserDetection,
        timeout: TimeInterval,
        session: URLSession = .shared) async throws -> [OpenCodeWorkspaceAccountMutationResult]
    {
        let cookieHeader = try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: self.opencodeSettingsSnapshot(tokenOverride: nil),
                provider: .opencode,
                browserDetection: browserDetection,
                allowCached: true),
            invalidCookie: OpenCodeSettingsError.invalidCookie,
            missingCookie: OpenCodeSettingsError.missingCookie)
        guard let tokenAccount = self.ensureOpenCodeTokenAccount(cookieHeader: cookieHeader) else {
            throw OpenCodeSettingsError.invalidCookie
        }
        let workspaces = try await OpenCodeWorkspaceDiscovery.discover(
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        return self.saveOpenCodeWorkspaces(
            workspaces,
            tokenAccountID: tokenAccount.id)
    }

    private func ensureOpenCodeTokenAccount(cookieHeader: String) -> ProviderTokenAccount? {
        guard let support = TokenAccountSupportCatalog.support(for: .opencode),
              case .cookieHeader = support.injection,
              let normalizedCookieHeader = OpenCodeWebCookieSupport.requestCookieHeader(from: cookieHeader)
        else {
            return nil
        }
        if let existing = self.tokenAccounts(for: .opencode).first(where: {
            TokenAccountSupportCatalog.normalizedCookieHeader($0.token, support: support)
                == normalizedCookieHeader
        }) {
            return existing
        }
        self.addTokenAccount(
            provider: .opencode,
            label: "OpenCode",
            token: normalizedCookieHeader)
        return self.tokenAccounts(for: .opencode).last
    }
}
