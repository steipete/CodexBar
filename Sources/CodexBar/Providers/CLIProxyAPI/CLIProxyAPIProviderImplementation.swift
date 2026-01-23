import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct CLIProxyAPIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cliproxyapi

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.cliproxyapiManagementURL
        _ = settings.cliproxyapiManagementKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if CLIProxyAPISettingsReader.managementURL(environment: context.environment) != nil,
           !(CLIProxyAPISettingsReader.managementKey(environment: context.environment)?.isEmpty ?? true)
        {
            return true
        }
        let url = CLIProxyAPISettingsReader.normalizeBaseURL(context.settings.cliproxyapiManagementURL)
        let key = context.settings.cliproxyapiManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return url != nil && !key.isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "cliproxyapi-management-url",
                title: "Management URL",
                subtitle: "Base address for the CLIProxyAPI management server.",
                kind: .plain,
                placeholder: "http://127.0.0.1:8317",
                binding: context.stringBinding(\.cliproxyapiManagementURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "cliproxyapi-management-key",
                title: "Management key",
                subtitle: "Key used to query auth files and quota.",
                kind: .secure,
                placeholder: "Paste management key…",
                binding: context.stringBinding(\.cliproxyapiManagementKey),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "cliproxyapi-sync",
                        title: "Sync accounts from proxy",
                        style: .bordered,
                        isVisible: nil,
                        perform: { await self.syncAccounts(context: context) }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureCLIProxyAPIManagementKeyLoaded() }),
        ]
    }

    @MainActor
    private func syncAccounts(context: ProviderSettingsContext) async {
        let statusKey = "cliproxyapi-sync"
        context.setStatusText(statusKey, "Syncing accounts…")
        defer { context.setStatusText(statusKey, nil) }

        let rawURL = context.settings.cliproxyapiManagementURL
        guard let baseURL = CLIProxyAPISettingsReader.normalizeBaseURL(rawURL) else {
            context.setStatusText(statusKey, "Invalid management URL")
            return
        }
        let key = context.settings.cliproxyapiManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            context.setStatusText(statusKey, "Missing management key")
            return
        }

        let client = CLIProxyAPIManagementClient(baseURL: baseURL, managementKey: key)
        do {
            let files = try await client.listAuthFiles()
            let accounts = self.makeTokenAccounts(files: files, settings: context.settings)
            let activeIndex = self.resolveActiveIndex(accounts: accounts, settings: context.settings)
            let data = ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: activeIndex)
            context.settings.updateProviderConfig(provider: .cliproxyapi) { entry in
                entry.tokenAccounts = data
            }
            context.setStatusText(statusKey, "Accounts synced")
        } catch {
            context.setStatusText(statusKey, "Sync failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func makeTokenAccounts(files: [CLIProxyAPIAuthFile], settings: SettingsStore) -> [ProviderTokenAccount] {
        let existing = settings.tokenAccountsData(for: .cliproxyapi)?.accounts ?? []
        let existingByToken = Dictionary(uniqueKeysWithValues: existing.map { ($0.token, $0) })
        let now = Date().timeIntervalSince1970

        return files.compactMap { file in
            guard let authIndex = file.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !authIndex.isEmpty
            else {
                return nil
            }
            let label = self.label(for: file)
            if let existing = existingByToken[authIndex] {
                return ProviderTokenAccount(
                    id: existing.id,
                    label: label,
                    token: authIndex,
                    addedAt: existing.addedAt,
                    lastUsed: existing.lastUsed)
            }
            return ProviderTokenAccount(
                id: UUID(),
                label: label,
                token: authIndex,
                addedAt: now,
                lastUsed: nil)
        }
    }

    @MainActor
    private func resolveActiveIndex(accounts: [ProviderTokenAccount], settings: SettingsStore) -> Int {
        guard let selected = settings.selectedTokenAccount(for: .cliproxyapi) else { return 0 }
        if let index = accounts.firstIndex(where: { $0.token == selected.token }) { return index }
        return 0
    }

    private func label(for file: CLIProxyAPIAuthFile) -> String {
        let provider = file.normalizedProvider.isEmpty ? "cli" : file.normalizedProvider
        let label = file.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = file.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = file.account?.trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = [provider]
        if let email, !email.isEmpty {
            parts.append(email)
        } else if let label, !label.isEmpty {
            parts.append(label)
        }
        if let account, !account.isEmpty, account != email {
            parts.append(account)
        }
        return parts.joined(separator: " • ")
    }
}
