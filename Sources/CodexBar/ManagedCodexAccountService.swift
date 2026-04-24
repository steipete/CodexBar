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
}

enum ManagedCodexAccountServiceError: Error, Equatable {
    case loginFailed
    case missingEmail
    case unsafeManagedHome(String)
    case deviceFlowTimedOut
    case deviceFlowRequestFailed(status: Int)
    case deviceFlowInvalidResponse
}

/// Progress phases surfaced to the coordinator / UI during a device-auth
/// login. The runner tells the service when to update each step; the service
/// forwards them through the `progress` closure provided by the caller.
enum ManagedCodexDeviceFlowProgress: Equatable {
    case requestingCode
    case awaitingUser(userCode: String, verificationURL: URL)
    case exchangingTokens
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
}

@MainActor
final class ManagedCodexAccountService {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let loginRunner: any ManagedCodexLoginRunning
    private let deviceFlowRunner: any ManagedCodexDeviceFlowRunning
    private let identityReader: any ManagedCodexIdentityReading
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        loginRunner: any ManagedCodexLoginRunning,
        deviceFlowRunner: any ManagedCodexDeviceFlowRunning = DefaultManagedCodexDeviceFlowRunner(),
        identityReader: any ManagedCodexIdentityReading,
        workspaceResolver: any ManagedCodexWorkspaceResolving = DefaultManagedCodexWorkspaceResolver(),
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.loginRunner = loginRunner
        self.deviceFlowRunner = deviceFlowRunner
        self.identityReader = identityReader
        self.workspaceResolver = workspaceResolver
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(
            store: FileManagedCodexAccountStore(fileManager: fileManager),
            homeFactory: ManagedCodexHomeFactory(fileManager: fileManager),
            loginRunner: DefaultManagedCodexLoginRunner(),
            deviceFlowRunner: DefaultManagedCodexDeviceFlowRunner(),
            identityReader: DefaultManagedCodexIdentityReader(),
            workspaceResolver: DefaultManagedCodexWorkspaceResolver(),
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

            let reconciled = try await self.reconcileAuthenticatedIdentity(
                snapshot: snapshot,
                homeURL: homeURL,
                existingAccountID: existingAccountID)
            account = reconciled.account
            existingHomePathsToDelete = reconciled.existingHomePathsToDelete
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        for existingHomePathToDelete in existingHomePathsToDelete where existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    /// Authenticates a managed Codex account using the native OAuth 2.0
    /// Device Authorization Grant, bypassing the `codex login` subprocess.
    ///
    /// The device flow runner fetches a user code, surfaces it through the
    /// `progress` closure, and polls until the user authorizes on another
    /// device or the session deadline is reached. Once tokens are exchanged
    /// we write them to the managed `auth.json` and then re-enter the same
    /// identity / workspace / reconciliation pipeline used by the CLI path.
    func authenticateManagedAccountWithDeviceFlow(
        existingAccountID: UUID? = nil,
        sessionTimeout: TimeInterval = 15 * 60,
        progress: @MainActor @escaping (ManagedCodexDeviceFlowProgress) -> Void)
        async throws -> ManagedCodexAccount
    {
        let snapshot = try self.store.loadAccounts()
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedCodexAccount
        let existingHomePathsToDelete: [String]

        do {
            progress(.requestingCode)
            let deviceCode: CodexDeviceFlow.DeviceCodeResponse
            do {
                deviceCode = try await self.deviceFlowRunner.requestDeviceCode()
            } catch let error as CodexDeviceFlow.Error {
                throw Self.mapDeviceFlowError(error)
            }

            progress(.awaitingUser(
                userCode: deviceCode.userCode,
                verificationURL: deviceCode.verificationURL))

            let credentials: CodexOAuthCredentials
            do {
                credentials = try await self.deviceFlowRunner.pollForTokens(
                    deviceAuthID: deviceCode.deviceAuthID,
                    userCode: deviceCode.userCode,
                    intervalSeconds: deviceCode.intervalSeconds,
                    deadline: Date().addingTimeInterval(sessionTimeout))
            } catch let error as CodexDeviceFlow.Error {
                throw Self.mapDeviceFlowError(error)
            }

            progress(.exchangingTokens)

            let scopedEnv = CodexHomeScope.scopedEnvironment(
                base: ProcessInfo.processInfo.environment,
                codexHome: homeURL.path)
            try CodexOAuthCredentialsStore.save(credentials, env: scopedEnv)

            let reconciled = try await self.reconcileAuthenticatedIdentity(
                snapshot: snapshot,
                homeURL: homeURL,
                existingAccountID: existingAccountID)
            account = reconciled.account
            existingHomePathsToDelete = reconciled.existingHomePathsToDelete
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        for existingHomePathToDelete in existingHomePathsToDelete where existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    /// Runs the device-auth flow against the ambient Codex home
    /// (`~/.codex/` unless `CODEX_HOME` is set) and writes the tokens in
    /// place, without touching CodexBar's managed account store.
    ///
    /// This is the native equivalent of `codex login` on a non-managed
    /// system account: it overwrites the same `auth.json` the CLI would
    /// overwrite. Caller is responsible for any post-save refresh of
    /// CodexBar state.
    func authenticateAmbientCodexAccountWithDeviceFlow(
        sessionTimeout: TimeInterval = 15 * 60,
        progress: @MainActor @escaping (ManagedCodexDeviceFlowProgress) -> Void)
        async throws
    {
        progress(.requestingCode)
        let deviceCode: CodexDeviceFlow.DeviceCodeResponse
        do {
            deviceCode = try await self.deviceFlowRunner.requestDeviceCode()
        } catch let error as CodexDeviceFlow.Error {
            throw Self.mapDeviceFlowError(error)
        }

        progress(.awaitingUser(
            userCode: deviceCode.userCode,
            verificationURL: deviceCode.verificationURL))

        let credentials: CodexOAuthCredentials
        do {
            credentials = try await self.deviceFlowRunner.pollForTokens(
                deviceAuthID: deviceCode.deviceAuthID,
                userCode: deviceCode.userCode,
                intervalSeconds: deviceCode.intervalSeconds,
                deadline: Date().addingTimeInterval(sessionTimeout))
        } catch let error as CodexDeviceFlow.Error {
            throw Self.mapDeviceFlowError(error)
        }

        progress(.exchangingTokens)

        // Ambient env = no `CODEX_HOME` override → writes to `~/.codex/auth.json`.
        try CodexOAuthCredentialsStore.save(credentials, env: ProcessInfo.processInfo.environment)
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

    /// Shared post-auth pipeline used by both the CLI login path and the
    /// native device-auth path. At this point `auth.json` has already been
    /// written under `homeURL`; we read the identity, resolve the workspace,
    /// reconcile with any existing entries, and persist.
    private func reconcileAuthenticatedIdentity(
        snapshot: ManagedCodexAccountSet,
        homeURL: URL,
        existingAccountID: UUID?)
        async throws -> (account: ManagedCodexAccount, existingHomePathsToDelete: [String])
    {
        let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
        guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEmail.isEmpty
        else {
            throw ManagedCodexAccountServiceError.missingEmail
        }
        let providerAccountID: String? = switch identity.identity {
        case let .providerAccount(id):
            ManagedCodexAccount.normalizeProviderAccountID(id)
        case .emailOnly, .unresolved:
            nil
        }
        let workspaceIdentity: CodexOpenAIWorkspaceIdentity? = if let providerAccountID {
            await self.workspaceResolver.resolveWorkspaceIdentity(
                homePath: homeURL.path,
                providerAccountID: providerAccountID)
        } else {
            nil
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

        let account = ManagedCodexAccount(
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
        let existingHomePathsToDelete = snapshot.accounts
            .filter { replacedAccountIDs.contains($0.id) }
            .map(\.managedHomePath)

        let updatedSnapshot = ManagedCodexAccountSet(
            version: snapshot.version,
            accounts: snapshot.accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account])
        try self.store.storeAccounts(updatedSnapshot)

        return (account, existingHomePathsToDelete)
    }

    private static func mapDeviceFlowError(_ error: CodexDeviceFlow.Error) -> ManagedCodexAccountServiceError {
        switch error {
        case .timedOut:
            .deviceFlowTimedOut
        case let .requestFailed(status, _):
            .deviceFlowRequestFailed(status: status)
        case .invalidResponse, .missingTokens:
            .deviceFlowInvalidResponse
        }
    }

    private func removeManagedHomeIfSafe(atPath path: String) throws {
        let homeURL = URL(fileURLWithPath: path, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
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
