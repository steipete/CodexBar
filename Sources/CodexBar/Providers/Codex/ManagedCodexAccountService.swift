import AppKit
import CodexBarCore
import Foundation

protocol ManagedCodexLoginRunning: Sendable {
    func run(homePath: String, timeout: TimeInterval) async -> CLILoginRunner.Result
}

protocol ManagedCodexIdentityReading: Sendable {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount
}

protocol ManagedCodexWorkspaceSelecting: Sendable {
    @MainActor
    func selectWorkspace(
        email: String,
        currentWorkspaceID: String?,
        workspaces: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
}

enum ManagedCodexAccountServiceError: Error, Equatable {
    case loginFailed(CLILoginRunner.Result)
    case missingEmail
    case savedAccountConflict
    case workspaceSelectionCancelled
    case unsafeManagedHome(String)
}

extension ManagedCodexAccountServiceError {
    var userFacingMessage: String {
        switch self {
        case let .loginFailed(result):
            CodexLoginAlertPresentation.managedLoginFailureMessage(for: result)
        case .missingEmail:
            L("managed_login_missing_email")
        case .savedAccountConflict:
            L("CodexBar could not update managed account storage.")
        case .workspaceSelectionCancelled:
            L("workspace_selection_cancelled")
        case let .unsafeManagedHome(path):
            String(format: L("unsafe_managed_home"), path)
        }
    }
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
    func run(homePath: String, timeout: TimeInterval) async -> CLILoginRunner.Result {
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
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedCodexAccount
        let existingHomePathsToDelete: [String]

        do {
            let result = await self.loginRunner.run(homePath: homeURL.path, timeout: timeout)
            guard case .success = result.outcome else { throw ManagedCodexAccountServiceError.loginFailed(result) }

            let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
            guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEmail.isEmpty
            else {
                throw ManagedCodexAccountServiceError.missingEmail
            }
            let authenticatedProviderAccountID: String? = switch identity.identity {
            case let .providerAccount(id):
                ManagedCodexAccount.normalizeWorkspaceAccountID(id)
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
            let committed = try ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
                let snapshot = try self.store.loadAccounts()
                let replacementSnapshot = try ManagedCodexAccountSet(
                    version: snapshot.version,
                    accounts: snapshot.accounts.filter {
                        guard $0.email == Self.normalizeEmail(rawEmail), $0.effectiveWorkspaceAccountID == nil
                        else { return true }
                        let canReplace = self.canReplaceLegacyAccount($0, providerAccountID: providerAccountID)
                        guard canReplace || providerAccountID != nil else {
                            throw ManagedCodexAccountServiceError.savedAccountConflict
                        }
                        return canReplace
                    })
                let existing = self.reconciledExistingAccount(
                    authenticatedEmail: rawEmail,
                    providerAccountID: providerAccountID,
                    existingAccountID: existingAccountID,
                    snapshot: replacementSnapshot)
                let persistedMetadata = self.persistedProviderMetadata(
                    authenticatedProviderAccountID: providerAccountID,
                    resolvedWorkspaceIdentity: workspaceIdentity,
                    existingAccount: existing)

                let account = ManagedCodexAccount(
                    id: existing?.id ?? UUID(),
                    email: rawEmail,
                    providerAccountID: persistedMetadata.providerAccountID,
                    workspaceLabel: persistedMetadata.workspaceLabel,
                    workspaceAccountID: persistedMetadata.workspaceAccountID,
                    authFingerprint: CodexAuthFingerprint.fingerprint(
                        homePath: homeURL.path,
                        fileManager: self.fileManager),
                    managedHomePath: homeURL.path,
                    createdAt: existing?.createdAt ?? now,
                    updatedAt: now,
                    lastAuthenticatedAt: now)
                let replacedAccountIDs = self.replacedAccountIDs(
                    authenticatedEmail: rawEmail,
                    providerAccountID: providerAccountID,
                    matchedAccountID: existing?.id,
                    snapshot: replacementSnapshot)
                let existingHomePathsToDelete = snapshot.accounts
                    .filter { replacedAccountIDs.contains($0.id) }
                    .map(\.managedHomePath)

                let updatedSnapshot = ManagedCodexAccountSet(
                    version: snapshot.version,
                    accounts: snapshot.accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account])
                try FileManagedCodexAccountStore.$mutation.withValue(.addOrReauth) {
                    try self.store.storeAccounts(updatedSnapshot)
                }
                return (account, existingHomePathsToDelete)
            }
            account = committed.0
            existingHomePathsToDelete = committed.1
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path, mutation: .addOrReauth)
            throw error
        }

        try? ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            let referencedHomes = try Set(self.store.loadAccounts().accounts.map(\.managedHomePath))
            for path in existingHomePathsToDelete where path != homeURL.path && !referencedHomes.contains(path) {
                try? self.removeManagedHomeIfSafe(atPath: path, mutation: .addOrReauth)
            }
        }
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        try ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            try self.removeManagedAccountLocked(id: id)
        }
    }

    private func removeManagedAccountLocked(id: UUID) throws {
        let snapshot = try self.store.loadAccounts()
        guard let account = snapshot.account(id: id) else { return }

        let remaining = snapshot.accounts.filter { $0.id != id }
        try FileManagedCodexAccountStore.$mutation.withValue(.remove) {
            try self.store.storeAccounts(ManagedCodexAccountSet(
                version: snapshot.version,
                accounts: remaining))
        }

        let homeStillReferenced = remaining.contains { $0.managedHomePath == account.managedHomePath }
        if homeStillReferenced == false {
            try? self.removeManagedHomeIfSafe(atPath: account.managedHomePath, mutation: .remove)
        }
    }

    private func removeManagedHomeIfSafe(atPath path: String, mutation: FileManagedCodexAccountStore.Mutation) throws {
        let homeURL = URL(fileURLWithPath: path, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
            FileManagedCodexAccountStore.logHomeDeletion(mutation: mutation)
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
           providerAccountID == nil || existingByID.effectiveWorkspaceAccountID == nil
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
                        $0.effectiveWorkspaceAccountID == nil &&
                        $0.email == normalizedEmail
                }
                .map(\.id)
            ids.formUnion(legacySameEmailIDs)
        }

        return ids
    }

    private func canReplaceLegacyAccount(_ account: ManagedCodexAccount, providerAccountID: String?) -> Bool {
        do {
            let data = try CodexCredentialFileAccess.read(at: CodexAuthFingerprint.authFileURL(
                homePath: account.managedHomePath))
            let identity = try PreparedPromotionContextBuilder.runtimeAccount(from: data)
            // Email-only metadata cannot authorize deleting another workspace or owner's credentials.
            guard identity.email == nil || identity.email == account.email else { return false }
            switch identity.identity {
            case let .providerAccount(id):
                return id == providerAccountID
            case let .emailOnly(normalizedEmail):
                return providerAccountID == nil && normalizedEmail == account.email
            case .unresolved:
                return false
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            return false
        }
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
            let isExistingProviderMatch =
                existingAccount?.effectiveWorkspaceAccountID == authenticatedProviderAccountID
            return (
                providerAccountID: authenticatedProviderAccountID,
                workspaceLabel: resolvedWorkspaceIdentity?.workspaceLabel
                    ?? (isExistingProviderMatch ? existingAccount?.workspaceLabel : nil),
                workspaceAccountID: resolvedWorkspaceIdentity?.workspaceAccountID ??
                    (isExistingProviderMatch ? existingAccount?.workspaceAccountID : nil) ??
                    authenticatedProviderAccountID)
        }

        guard let existingAccount, existingAccount.effectiveWorkspaceAccountID != nil else {
            return (providerAccountID: nil, workspaceLabel: nil, workspaceAccountID: nil)
        }

        return (
            providerAccountID: existingAccount.providerAccountID,
            workspaceLabel: existingAccount.workspaceLabel,
            workspaceAccountID: existingAccount.effectiveWorkspaceAccountID)
    }
}
