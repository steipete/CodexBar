import AppKit
import CodexBarCore
import Foundation

protocol ManagedCodexHomeProducing: Sendable {
    func makeHomeURL() -> URL
    func validateManagedHomeForDeletion(_ url: URL) throws
}

protocol ManagedCodexLoginRunning: Sendable {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result
}

protocol ManagedCodexIdentityReading: Sendable {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount
}

protocol ManagedCodexWorkspaceResolving: Sendable {
    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity]
}

extension ManagedCodexWorkspaceResolving {
    func availableWorkspaceIdentities(homePath _: String) async -> [CodexOpenAIWorkspaceIdentity] {
        []
    }
}

protocol ManagedCodexWorkspaceSelecting: Sendable {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
}

enum ManagedCodexAccountServiceError: Error, Equatable {
    case loginFailed
    case missingEmail
    case workspaceSelectionCancelled
    case unsafeManagedHome(String)
}

struct ManagedCodexHomeFactory: ManagedCodexHomeProducing {
    let root: URL

    init(root: URL = Self.defaultRootURL(), fileManager: FileManager = .default) {
        let standardizedRoot = root.standardizedFileURL
        if standardizedRoot.path != root.path {
            self.root = standardizedRoot
        } else {
            self.root = root
        }
        _ = fileManager
    }

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        let rootPath = self.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(rootPrefix), targetPath != rootPath else {
            throw ManagedCodexAccountServiceError.unsafeManagedHome(url.path)
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }
}

struct DefaultManagedCodexLoginRunner: ManagedCodexLoginRunning {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result {
        await CodexLoginRunner.run(homePath: homePath, timeout: timeout)
    }
}

struct DefaultManagedCodexIdentityReader: ManagedCodexIdentityReading {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        return UsageFetcher(environment: env).loadAuthBackedCodexAccount()
    }
}

struct DefaultManagedCodexWorkspaceResolver: ManagedCodexWorkspaceResolving {
    private let workspaceCache: CodexOpenAIWorkspaceIdentityCache

    init(
        workspaceCache: CodexOpenAIWorkspaceIdentityCache = CodexOpenAIWorkspaceIdentityCache())
    {
        self.workspaceCache = workspaceCache
    }

    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity? {
        let normalizedProviderAccountID = ManagedCodexAccount.normalizeProviderAccountID(providerAccountID)
            ?? providerAccountID
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)

        if let credentials = try? CodexOAuthCredentialsStore.load(env: env),
           let authoritativeIdentity = try? await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials)
        {
            try? self.workspaceCache.store(authoritativeIdentity)
            return authoritativeIdentity
        }

        let cachedLabel = self.workspaceCache.workspaceLabel(for: normalizedProviderAccountID)
        return CodexOpenAIWorkspaceIdentity(
            workspaceAccountID: normalizedProviderAccountID,
            workspaceLabel: cachedLabel)
    }

    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity] {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: env),
              let identities = try? await CodexOpenAIWorkspaceResolver.listWorkspaces(credentials: credentials)
        else {
            return []
        }

        for identity in identities {
            try? self.workspaceCache.store(identity)
        }
        return identities
    }
}

struct CodexWorkspaceAlertSelector: ManagedCodexWorkspaceSelecting {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
    {
        guard workspaces.count > 1 else { return workspaces.first }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        let sortedWorkspaces = workspaces.sorted { lhs, rhs in
            self.workspaceTitle(lhs) < self.workspaceTitle(rhs)
        }
        for workspace in sortedWorkspaces {
            popup.addItem(withTitle: self.workspaceTitle(workspace))
            popup.lastItem?.representedObject = workspace.workspaceAccountID
        }
        if let currentWorkspaceID,
           let selectedIndex = sortedWorkspaces.firstIndex(where: { $0.workspaceAccountID == currentWorkspaceID })
        {
            popup.selectItem(at: selectedIndex)
        }

        let alert = NSAlert()
        alert.messageText = L("Choose Codex workspace")
        alert.informativeText = String(format: L("multiple_workspaces_found"), email)
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Add Workspace"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let selectedWorkspaceID = popup.selectedItem?.representedObject as? String
        return sortedWorkspaces.first { $0.workspaceAccountID == selectedWorkspaceID }
    }

    private func workspaceTitle(_ workspace: CodexOpenAIWorkspaceIdentity) -> String {
        workspace.workspaceLabel ?? workspace.workspaceAccountID
    }
}

@MainActor
final class ManagedCodexAccountService {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let loginRunner: any ManagedCodexLoginRunning
    private let identityReader: any ManagedCodexIdentityReading
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let workspaceSelector: any ManagedCodexWorkspaceSelecting
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        loginRunner: any ManagedCodexLoginRunning,
        identityReader: any ManagedCodexIdentityReading,
        workspaceResolver: any ManagedCodexWorkspaceResolving = DefaultManagedCodexWorkspaceResolver(),
        workspaceSelector: any ManagedCodexWorkspaceSelecting = CodexWorkspaceAlertSelector(),
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.loginRunner = loginRunner
        self.identityReader = identityReader
        self.workspaceResolver = workspaceResolver
        self.workspaceSelector = workspaceSelector
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(
            store: FileManagedCodexAccountStore(fileManager: fileManager),
            homeFactory: ManagedCodexHomeFactory(fileManager: fileManager),
            loginRunner: DefaultManagedCodexLoginRunner(),
            identityReader: DefaultManagedCodexIdentityReader(),
            workspaceResolver: DefaultManagedCodexWorkspaceResolver(),
            workspaceSelector: CodexWorkspaceAlertSelector(),
            fileManager: fileManager)
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        let snapshot = try self.store.loadAccounts()
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedCodexAccount
        let existingHomePathsToDelete: [String]

        do {
            let result = await self.loginRunner.run(homePath: homeURL.path, timeout: timeout)
            guard case .success = result.outcome else { throw ManagedCodexAccountServiceError.loginFailed }

            let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
            guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEmail.isEmpty
            else {
                throw ManagedCodexAccountServiceError.missingEmail
            }
            let authenticatedProviderAccountID: String? = switch identity.identity {
            case let .providerAccount(id):
                ManagedCodexAccount.normalizeProviderAccountID(id)
            case .emailOnly, .unresolved:
                nil
            }
            let selectedWorkspace = try await self.selectedWorkspaceIdentity(
                email: rawEmail,
                homePath: homeURL.path,
                authenticatedProviderAccountID: authenticatedProviderAccountID)
            let providerAccountID = selectedWorkspace?.workspaceAccountID ?? authenticatedProviderAccountID
            let workspaceIdentity: CodexOpenAIWorkspaceIdentity? = if let selectedWorkspace {
                selectedWorkspace
            } else {
                await self.resolvedWorkspaceIdentity(
                    homePath: homeURL.path,
                    providerAccountID: providerAccountID)
            }

            let now = Date().timeIntervalSince1970
            let existing = self.reconciledExistingAccount(
                authenticatedEmail: rawEmail,
                providerAccountID: providerAccountID,
                existingAccountID: existingAccountID,
                snapshot: snapshot)
            let persistedMetadata = self.persistedProviderMetadata(
                authenticatedProviderAccountID: providerAccountID,
                resolvedWorkspaceIdentity: workspaceIdentity,
                existingAccount: existing)

            account = ManagedCodexAccount(
                id: existing?.id ?? UUID(),
                email: rawEmail,
                providerAccountID: persistedMetadata.providerAccountID,
                workspaceLabel: persistedMetadata.workspaceLabel,
                workspaceAccountID: persistedMetadata.workspaceAccountID,
                managedHomePath: homeURL.path,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastAuthenticatedAt: now)
            let replacedAccountIDs = self.replacedAccountIDs(
                authenticatedEmail: rawEmail,
                providerAccountID: providerAccountID,
                existingAccountID: existingAccountID,
                matchedAccountID: existing?.id,
                snapshot: snapshot)
            existingHomePathsToDelete = snapshot.accounts
                .filter { replacedAccountIDs.contains($0.id) }
                .map(\.managedHomePath)

            let updatedSnapshot = ManagedCodexAccountSet(
                version: snapshot.version,
                accounts: snapshot.accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account])
            try self.store.storeAccounts(updatedSnapshot)
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        for existingHomePathToDelete in existingHomePathsToDelete where existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        let snapshot = try self.store.loadAccounts()
        guard let account = snapshot.account(id: id) else { return }

        let homeURL = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)

        let remaining = snapshot.accounts.filter { $0.id != id }
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: snapshot.version,
            accounts: remaining))

        if self.fileManager.fileExists(atPath: homeURL.path) {
            try? self.fileManager.removeItem(at: homeURL)
        }
    }

    private func removeManagedHomeIfSafe(atPath path: String) throws {
        let homeURL = URL(fileURLWithPath: path, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
    }

    private func selectedWorkspaceIdentity(
        email: String,
        homePath: String,
        authenticatedProviderAccountID: String?) async throws -> CodexOpenAIWorkspaceIdentity?
    {
        let workspaces = await self.workspaceResolver.availableWorkspaceIdentities(homePath: homePath)
        guard workspaces.count > 1 else {
            return workspaces.first { $0.workspaceAccountID == authenticatedProviderAccountID }
        }
        guard let selected = await self.workspaceSelector.selectWorkspace(
            email: email,
            currentWorkspaceID: authenticatedProviderAccountID,
            workspaces: workspaces)
        else {
            throw ManagedCodexAccountServiceError.workspaceSelectionCancelled
        }
        try self.persistSelectedWorkspaceID(selected.workspaceAccountID, homePath: homePath)
        return selected
    }

    private func resolvedWorkspaceIdentity(
        homePath: String,
        providerAccountID: String?) async -> CodexOpenAIWorkspaceIdentity?
    {
        guard let providerAccountID else { return nil }
        return await self.workspaceResolver.resolveWorkspaceIdentity(
            homePath: homePath,
            providerAccountID: providerAccountID)
    }

    private func persistSelectedWorkspaceID(_ workspaceID: String, homePath: String) throws {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        let credentials = try CodexOAuthCredentialsStore.load(env: env)
        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                idToken: credentials.idToken,
                accountId: workspaceID,
                lastRefresh: credentials.lastRefresh),
            env: env)
    }

    private func reconciledExistingAccount(
        authenticatedEmail: String,
        providerAccountID: String?,
        existingAccountID: UUID?,
        snapshot: ManagedCodexAccountSet)
        -> ManagedCodexAccount?
    {
        if let providerAccountID,
           let existingByProviderAccountID = snapshot.account(
               email: authenticatedEmail,
               providerAccountID: providerAccountID)
        {
            return existingByProviderAccountID
        }
        if let existingAccountID,
           let existingByID = snapshot.account(id: existingAccountID),
           existingByID.email == Self.normalizeEmail(authenticatedEmail),
           providerAccountID == nil || existingByID.providerAccountID == nil
        {
            return existingByID
        }
        guard providerAccountID == nil else {
            return nil
        }
        // Email-only reconciliation is a legacy/hardening fallback. Once an auth payload carries a
        // provider account ID, matching must stay on that ID so same-email workspaces can coexist.
        return snapshot.account(email: authenticatedEmail)
    }

    private func replacedAccountIDs(
        authenticatedEmail: String,
        providerAccountID: String?,
        existingAccountID: UUID?,
        matchedAccountID: UUID?,
        snapshot: ManagedCodexAccountSet) -> Set<UUID>
    {
        var ids: Set<UUID> = []
        let normalizedEmail = Self.normalizeEmail(authenticatedEmail)
        if let matchedAccountID {
            ids.insert(matchedAccountID)
        }

        if providerAccountID != nil {
            let legacySameEmailIDs = snapshot.accounts
                .filter {
                    $0.id != matchedAccountID &&
                        $0.providerAccountID == nil &&
                        $0.email == normalizedEmail
                }
                .map(\.id)
            ids.formUnion(legacySameEmailIDs)
        }

        guard let existingAccountID,
              existingAccountID != matchedAccountID,
              let existingByID = snapshot.account(id: existingAccountID)
        else {
            return ids
        }

        if existingByID.providerAccountID == nil,
           existingByID.email == normalizedEmail,
           providerAccountID != nil
        {
            ids.insert(existingAccountID)
        }
        return ids
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func persistedProviderMetadata(
        authenticatedProviderAccountID: String?,
        resolvedWorkspaceIdentity: CodexOpenAIWorkspaceIdentity?,
        existingAccount: ManagedCodexAccount?) -> (
        providerAccountID: String?,
        workspaceLabel: String?,
        workspaceAccountID: String?)
    {
        if let authenticatedProviderAccountID {
            let isExistingProviderMatch = existingAccount?.providerAccountID == authenticatedProviderAccountID
            return (
                providerAccountID: authenticatedProviderAccountID,
                workspaceLabel: resolvedWorkspaceIdentity?.workspaceLabel
                    ?? (isExistingProviderMatch ? existingAccount?.workspaceLabel : nil),
                workspaceAccountID: resolvedWorkspaceIdentity?.workspaceAccountID ??
                    (isExistingProviderMatch ? existingAccount?.workspaceAccountID : nil) ??
                    authenticatedProviderAccountID)
        }

        guard let existingAccount, existingAccount.providerAccountID != nil else {
            return (providerAccountID: nil, workspaceLabel: nil, workspaceAccountID: nil)
        }

        return (
            providerAccountID: existingAccount.providerAccountID,
            workspaceLabel: existingAccount.workspaceLabel,
            workspaceAccountID: existingAccount.workspaceAccountID ?? existingAccount.providerAccountID)
    }
}
