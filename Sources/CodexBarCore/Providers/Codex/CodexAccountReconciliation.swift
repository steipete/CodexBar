import Foundation

public struct CodexResolvedActiveSource: Equatable, Sendable {
    public let persistedSource: CodexActiveSource
    public let resolvedSource: CodexActiveSource

    public init(persistedSource: CodexActiveSource, resolvedSource: CodexActiveSource) {
        self.persistedSource = persistedSource
        self.resolvedSource = resolvedSource
    }

    public var requiresPersistenceCorrection: Bool {
        self.persistedSource != self.resolvedSource
    }
}

public enum CodexActiveSourceResolver {
    public static func resolve(from snapshot: CodexAccountReconciliationSnapshot) -> CodexResolvedActiveSource {
        let persistedSource = snapshot.activeSource
        let resolvedSource: CodexActiveSource = switch persistedSource {
        case .liveSystem:
            .liveSystem
        case let .managedAccount(id):
            if let activeStoredAccount = snapshot.activeStoredAccount {
                self.resolvedSource(for: activeStoredAccount, snapshot: snapshot)
            } else {
                snapshot.liveSystemAccount != nil ? .liveSystem : .managedAccount(id: id)
            }
        case let .profileHome(path):
            if let normalizedPath = snapshot.configuredProfileHomePath(path: path) {
                self.resolvedProfileSource(path: normalizedPath, snapshot: snapshot)
            } else {
                .liveSystem
            }
        }

        return CodexResolvedActiveSource(
            persistedSource: persistedSource,
            resolvedSource: resolvedSource)
    }

    private static func resolvedProfileSource(
        path: String,
        snapshot: CodexAccountReconciliationSnapshot) -> CodexActiveSource
    {
        if let livePath = snapshot.liveSystemAccount.flatMap({
            CodexHomeScope.normalizedHomePath($0.codexHomePath)
        }), livePath == path {
            return .liveSystem
        }

        if let storedAccount = snapshot.storedAccounts.first(where: {
            CodexHomeScope.normalizedHomePath($0.managedHomePath) == path
        }) {
            return self.resolvedSource(for: storedAccount, snapshot: snapshot)
        }

        return .profileHome(path: path)
    }

    private static func resolvedSource(
        for storedAccount: ManagedCodexAccount,
        snapshot: CodexAccountReconciliationSnapshot) -> CodexActiveSource
    {
        self.matchesLiveSystemAccount(
            storedAccount: storedAccount,
            snapshot: snapshot,
            liveSystemAccount: snapshot.liveSystemAccount) ? .liveSystem : .managedAccount(id: storedAccount.id)
    }

    private static func matchesLiveSystemAccount(
        storedAccount: ManagedCodexAccount,
        snapshot: CodexAccountReconciliationSnapshot,
        liveSystemAccount: ObservedSystemCodexAccount?) -> Bool
    {
        guard let liveSystemAccount else { return false }
        if let storedFingerprint = storedAccount.authFingerprint,
           let liveFingerprint = liveSystemAccount.authFingerprint,
           storedFingerprint == liveFingerprint
        {
            return true
        }
        return CodexIdentityMatcher.matches(
            snapshot.runtimeIdentity(for: storedAccount),
            lhsEmail: snapshot.runtimeEmail(for: storedAccount),
            snapshot.runtimeIdentity(for: liveSystemAccount),
            rhsEmail: liveSystemAccount.email)
    }
}

public struct CodexAccountReconciliationSnapshot: Equatable, Sendable {
    public let storedAccounts: [ManagedCodexAccount]
    public let activeStoredAccount: ManagedCodexAccount?
    public let liveSystemAccount: ObservedSystemCodexAccount?
    public let profileHomeAccounts: [ObservedSystemCodexAccount]
    public let profileHomePaths: [String]
    public let matchingStoredAccountForLiveSystemAccount: ManagedCodexAccount?
    public let activeSource: CodexActiveSource
    public let hasUnreadableAddedAccountStore: Bool
    public let storedAccountRuntimeIdentities: [UUID: CodexIdentity]
    public let storedAccountRuntimeEmails: [UUID: String]

    public init(
        storedAccounts: [ManagedCodexAccount],
        activeStoredAccount: ManagedCodexAccount?,
        liveSystemAccount: ObservedSystemCodexAccount?,
        profileHomeAccounts: [ObservedSystemCodexAccount] = [],
        profileHomePaths: [String]? = nil,
        matchingStoredAccountForLiveSystemAccount: ManagedCodexAccount?,
        activeSource: CodexActiveSource,
        hasUnreadableAddedAccountStore: Bool,
        storedAccountRuntimeIdentities: [UUID: CodexIdentity] = [:],
        storedAccountRuntimeEmails: [UUID: String] = [:])
    {
        self.storedAccounts = storedAccounts
        self.activeStoredAccount = activeStoredAccount
        self.liveSystemAccount = liveSystemAccount
        self.profileHomeAccounts = Self.uniqueProfileHomeAccounts(profileHomeAccounts)
        self.profileHomePaths = Self.uniqueNormalizedPaths(
            profileHomePaths ?? profileHomeAccounts.map(\.codexHomePath))
        self.matchingStoredAccountForLiveSystemAccount = matchingStoredAccountForLiveSystemAccount
        self.activeSource = activeSource
        self.hasUnreadableAddedAccountStore = hasUnreadableAddedAccountStore
        self.storedAccountRuntimeIdentities = storedAccountRuntimeIdentities
        self.storedAccountRuntimeEmails = storedAccountRuntimeEmails
    }

    public static func == (lhs: CodexAccountReconciliationSnapshot, rhs: CodexAccountReconciliationSnapshot) -> Bool {
        lhs.storedAccounts.map(AccountIdentity.init) == rhs.storedAccounts.map(AccountIdentity.init)
            && lhs.activeStoredAccount.map(AccountIdentity.init) == rhs.activeStoredAccount.map(AccountIdentity.init)
            && lhs.liveSystemAccount == rhs.liveSystemAccount
            && lhs.profileHomeAccounts == rhs.profileHomeAccounts
            && lhs.profileHomePaths == rhs.profileHomePaths
            && lhs.matchingStoredAccountForLiveSystemAccount.map(AccountIdentity.init)
            == rhs.matchingStoredAccountForLiveSystemAccount.map(AccountIdentity.init)
            && lhs.activeSource == rhs.activeSource
            && lhs.hasUnreadableAddedAccountStore == rhs.hasUnreadableAddedAccountStore
            && lhs.storedAccountRuntimeIdentities == rhs.storedAccountRuntimeIdentities
            && lhs.storedAccountRuntimeEmails == rhs.storedAccountRuntimeEmails
    }

    public func runtimeIdentity(for storedAccount: ManagedCodexAccount) -> CodexIdentity {
        self.storedAccountRuntimeIdentities[storedAccount.id]
            ?? CodexIdentityResolver.resolve(accountId: nil, email: storedAccount.email)
    }

    public func runtimeEmail(for storedAccount: ManagedCodexAccount) -> String {
        self.storedAccountRuntimeEmails[storedAccount.id]
            ?? Self.normalizeEmail(storedAccount.email)
    }

    public func runtimeIdentity(for liveSystemAccount: ObservedSystemCodexAccount) -> CodexIdentity {
        CodexIdentityMatcher.normalized(
            liveSystemAccount.identity,
            fallbackEmail: liveSystemAccount.email)
    }

    public func profileHomeAccount(path: String) -> ObservedSystemCodexAccount? {
        guard let normalizedPath = CodexHomeScope.normalizedHomePath(path) else { return nil }
        return self.profileHomeAccounts.first {
            CodexHomeScope.normalizedHomePath($0.codexHomePath) == normalizedPath
        }
    }

    public func configuredProfileHomePath(path: String) -> String? {
        guard let normalizedPath = CodexHomeScope.normalizedHomePath(path),
              self.profileHomePaths.contains(normalizedPath)
        else {
            return nil
        }
        return normalizedPath
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniqueProfileHomeAccounts(
        _ accounts: [ObservedSystemCodexAccount]) -> [ObservedSystemCodexAccount]
    {
        var seenPaths: Set<String> = []
        var result: [ObservedSystemCodexAccount] = []
        for account in accounts {
            let path = CodexHomeScope.normalizedHomePath(account.codexHomePath) ?? account.codexHomePath
            guard seenPaths.insert(path).inserted else { continue }
            result.append(account)
        }
        return result
    }

    private static func uniqueNormalizedPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard let normalizedPath = CodexHomeScope.normalizedHomePath(path),
                  seen.insert(normalizedPath).inserted
            else {
                return nil
            }
            return normalizedPath
        }
    }
}

public struct DefaultCodexAccountReconciler: Sendable {
    public let storeLoader: @Sendable () throws -> ManagedCodexAccountSet
    public let systemObserver: any CodexSystemAccountObserving
    public let activeSource: CodexActiveSource
    public let baseEnvironment: [String: String]
    public let profileHomePaths: [String]
    public let managedEnvironmentBuilder: @Sendable ([String: String], ManagedCodexAccount) -> [String: String]

    public init(
        storeLoader: @escaping @Sendable () throws -> ManagedCodexAccountSet = {
            try FileManagedCodexAccountStore().loadAccounts()
        },
        systemObserver: any CodexSystemAccountObserving = DefaultCodexSystemAccountObserver(),
        activeSource: CodexActiveSource = .liveSystem,
        baseEnvironment: [String: String],
        profileHomePaths: [String] = [],
        managedEnvironmentBuilder: @escaping @Sendable ([String: String], ManagedCodexAccount)
            -> [String: String] = { baseEnvironment, account in
                CodexHomeScope.scopedEnvironment(base: baseEnvironment, codexHome: account.managedHomePath)
            })
    {
        self.storeLoader = storeLoader
        self.systemObserver = systemObserver
        self.activeSource = activeSource
        self.baseEnvironment = baseEnvironment
        self.profileHomePaths = Self.uniqueNormalizedPaths(profileHomePaths)
        self.managedEnvironmentBuilder = managedEnvironmentBuilder
    }

    public func loadSnapshot() -> CodexAccountReconciliationSnapshot {
        let liveSystemAccount = self.loadLiveSystemAccount()
        let profileHomeAccounts = self.loadProfileHomeAccounts(liveSystemAccount: liveSystemAccount)

        do {
            let accounts = try self.storeLoader()
            let runtimeAccounts = Dictionary(uniqueKeysWithValues: accounts.accounts.map { account in
                let runtimeAccount = self.loadRuntimeAccount(for: account)
                return (account.id, runtimeAccount)
            })
            let activeStoredAccount: ManagedCodexAccount? = switch self.activeSource {
            case let .managedAccount(id):
                accounts.account(id: id)
            case .liveSystem, .profileHome:
                nil
            }
            let matchingStoredAccountForLiveSystemAccount = liveSystemAccount.flatMap { liveAccount in
                if let liveFingerprint = liveAccount.authFingerprint,
                   let exactFingerprintMatch = accounts.accounts.first(where: {
                       $0.authFingerprint == liveFingerprint
                   })
                {
                    return exactFingerprintMatch
                }
                return accounts.accounts.first { account in
                    guard let runtimeAccount = runtimeAccounts[account.id] else { return false }
                    return CodexIdentityMatcher.matches(
                        runtimeAccount.identity,
                        lhsEmail: runtimeAccount.email,
                        self.runtimeIdentity(for: liveAccount),
                        rhsEmail: liveAccount.email)
                }
            }

            return CodexAccountReconciliationSnapshot(
                storedAccounts: accounts.accounts,
                activeStoredAccount: activeStoredAccount,
                liveSystemAccount: liveSystemAccount,
                profileHomeAccounts: self.profileHomeAccounts(
                    profileHomeAccounts,
                    excludingManagedAccounts: accounts.accounts),
                profileHomePaths: self.profileHomePaths,
                matchingStoredAccountForLiveSystemAccount: matchingStoredAccountForLiveSystemAccount,
                activeSource: self.activeSource,
                hasUnreadableAddedAccountStore: false,
                storedAccountRuntimeIdentities: runtimeAccounts.mapValues(\.identity),
                storedAccountRuntimeEmails: runtimeAccounts.mapValues(\.email))
        } catch {
            return CodexAccountReconciliationSnapshot(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: liveSystemAccount,
                profileHomeAccounts: profileHomeAccounts,
                profileHomePaths: self.profileHomePaths,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: self.activeSource,
                hasUnreadableAddedAccountStore: true)
        }
    }

    private func loadProfileHomeAccounts(
        liveSystemAccount: ObservedSystemCodexAccount?) -> [ObservedSystemCodexAccount]
    {
        let livePath = liveSystemAccount.flatMap { CodexHomeScope.normalizedHomePath($0.codexHomePath) }
        return self.profileHomePaths.compactMap { path in
            guard path != livePath else { return nil }
            return self.loadProfileHomeAccount(homePath: path)
        }
    }

    private func loadProfileHomeAccount(homePath: String) -> ObservedSystemCodexAccount? {
        let environment = CodexHomeScope.scopedEnvironment(base: self.baseEnvironment, codexHome: homePath)
        let account = UsageFetcher(environment: environment).loadAuthBackedCodexAccount()

        guard let rawEmail = account.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEmail.isEmpty
        else {
            return nil
        }

        let providerAccountID: String? = switch account.identity {
        case let .providerAccount(id):
            ManagedCodexAccount.normalizeProviderAccountID(id)
        case .emailOnly, .unresolved:
            nil
        }

        return ObservedSystemCodexAccount(
            email: rawEmail.lowercased(),
            workspaceAccountID: providerAccountID,
            authFingerprint: CodexAuthFingerprint.fingerprint(homePath: homePath),
            codexHomePath: homePath,
            observedAt: Date(),
            identity: account.identity)
    }

    private func loadLiveSystemAccount() -> ObservedSystemCodexAccount? {
        do {
            guard let account = try self.systemObserver.loadSystemAccount(environment: self.baseEnvironment) else {
                return nil
            }
            let normalizedEmail = Self.normalizeEmail(account.email)
            guard !normalizedEmail.isEmpty else {
                return nil
            }
            return ObservedSystemCodexAccount(
                email: normalizedEmail,
                workspaceLabel: account.workspaceLabel,
                workspaceAccountID: account.workspaceAccountID,
                authFingerprint: account.authFingerprint,
                codexHomePath: account.codexHomePath,
                observedAt: account.observedAt,
                identity: self.runtimeIdentity(for: account))
        } catch {
            return nil
        }
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func loadRuntimeAccount(for account: ManagedCodexAccount) -> RuntimeManagedCodexAccount {
        let scopedEnvironment = self.managedEnvironmentBuilder(self.baseEnvironment, account)
        let authBackedAccount = UsageFetcher(environment: scopedEnvironment).loadAuthBackedCodexAccount()
        let email = Self.normalizeEmail(authBackedAccount.email ?? account.email)
        let identity = CodexIdentityMatcher.normalized(authBackedAccount.identity, fallbackEmail: email)

        return RuntimeManagedCodexAccount(
            email: email,
            identity: identity)
    }

    private func profileHomeAccounts(
        _ profileHomeAccounts: [ObservedSystemCodexAccount],
        excludingManagedAccounts managedAccounts: [ManagedCodexAccount]) -> [ObservedSystemCodexAccount]
    {
        let managedPaths = Set(managedAccounts.compactMap { CodexHomeScope.normalizedHomePath($0.managedHomePath) })
        return profileHomeAccounts.filter { account in
            guard let path = CodexHomeScope.normalizedHomePath(account.codexHomePath) else { return false }
            return !managedPaths.contains(path)
        }
    }

    private func runtimeIdentity(for liveSystemAccount: ObservedSystemCodexAccount) -> CodexIdentity {
        CodexIdentityMatcher.normalized(
            liveSystemAccount.identity,
            fallbackEmail: liveSystemAccount.email)
    }

    private static func uniqueNormalizedPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths.compactMap({ CodexHomeScope.normalizedHomePath($0) }) {
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }
}

public enum CodexIdentityMatcher {
    public static func matches(_ lhs: CodexIdentity, _ rhs: CodexIdentity) -> Bool {
        switch (lhs, rhs) {
        case let (.providerAccount(leftID), .providerAccount(rightID)):
            leftID == rightID
        case let (.emailOnly(leftEmail), .emailOnly(rightEmail)):
            leftEmail == rightEmail
        default:
            false
        }
    }

    public static func matches(
        _ lhs: CodexIdentity,
        lhsEmail: String?,
        _ rhs: CodexIdentity,
        rhsEmail: String?) -> Bool
    {
        guard self.matches(lhs, rhs) else { return false }
        guard case .providerAccount = lhs, case .providerAccount = rhs else { return true }
        guard let normalizedLeftEmail = CodexIdentityResolver.normalizeEmail(lhsEmail),
              let normalizedRightEmail = CodexIdentityResolver.normalizeEmail(rhsEmail)
        else {
            return true
        }
        return normalizedLeftEmail == normalizedRightEmail
    }

    public static func normalized(_ identity: CodexIdentity, fallbackEmail: String) -> CodexIdentity {
        switch identity {
        case .providerAccount:
            identity
        case let .emailOnly(normalizedEmail):
            CodexIdentityResolver.resolve(accountId: nil, email: normalizedEmail)
        case .unresolved:
            CodexIdentityResolver.resolve(accountId: nil, email: fallbackEmail)
        }
    }

    public static func selectionKey(for identity: CodexIdentity, fallbackEmail: String) -> String {
        switch self.normalized(identity, fallbackEmail: fallbackEmail) {
        case let .providerAccount(id):
            "provider:\(id)"
        case let .emailOnly(normalizedEmail):
            "email:\(normalizedEmail)"
        case .unresolved:
            "unresolved:\(fallbackEmail)"
        }
    }
}

private struct RuntimeManagedCodexAccount {
    let email: String
    let identity: CodexIdentity
}

private struct AccountIdentity: Equatable {
    let id: UUID
    let email: String
    let providerAccountID: String?
    let workspaceLabel: String?
    let workspaceAccountID: String?
    let managedHomePath: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval
    let lastAuthenticatedAt: TimeInterval?
    let authFingerprint: String?

    init(_ account: ManagedCodexAccount) {
        self.id = account.id
        self.email = account.email
        self.providerAccountID = account.providerAccountID
        self.workspaceLabel = account.workspaceLabel
        self.workspaceAccountID = account.workspaceAccountID
        self.managedHomePath = account.managedHomePath
        self.createdAt = account.createdAt
        self.updatedAt = account.updatedAt
        self.lastAuthenticatedAt = account.lastAuthenticatedAt
        self.authFingerprint = account.authFingerprint
    }
}
