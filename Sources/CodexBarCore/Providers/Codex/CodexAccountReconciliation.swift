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
                self.matchesLiveSystemAccount(
                    storedAccount: activeStoredAccount,
                    snapshot: snapshot,
                    liveSystemAccount: snapshot.liveSystemAccount) ? .liveSystem : .managedAccount(id: id)
            } else {
                snapshot.liveSystemAccount != nil ? .liveSystem : .managedAccount(id: id)
            }
        }

        return CodexResolvedActiveSource(
            persistedSource: persistedSource,
            resolvedSource: resolvedSource)
    }

    private static func matchesLiveSystemAccount(
        storedAccount: ManagedCodexAccount,
        snapshot: CodexAccountReconciliationSnapshot,
        liveSystemAccount: ObservedSystemCodexAccount?) -> Bool
    {
        guard let liveSystemAccount else { return false }
        return CodexIdentityMatcher.matches(
            snapshot.runtimeIdentity(for: storedAccount),
            snapshot.runtimeIdentity(for: liveSystemAccount))
    }
}

public struct CodexAccountReconciliationSnapshot: Equatable, Sendable {
    public let storedAccounts: [ManagedCodexAccount]
    public let activeStoredAccount: ManagedCodexAccount?
    public let liveSystemAccount: ObservedSystemCodexAccount?
    public let matchingStoredAccountForLiveSystemAccount: ManagedCodexAccount?
    public let activeSource: CodexActiveSource
    public let hasUnreadableAddedAccountStore: Bool
    public let storedAccountRuntimeIdentities: [UUID: CodexIdentity]
    public let storedAccountRuntimeEmails: [UUID: String]

    public init(
        storedAccounts: [ManagedCodexAccount],
        activeStoredAccount: ManagedCodexAccount?,
        liveSystemAccount: ObservedSystemCodexAccount?,
        matchingStoredAccountForLiveSystemAccount: ManagedCodexAccount?,
        activeSource: CodexActiveSource,
        hasUnreadableAddedAccountStore: Bool,
        storedAccountRuntimeIdentities: [UUID: CodexIdentity] = [:],
        storedAccountRuntimeEmails: [UUID: String] = [:])
    {
        self.storedAccounts = storedAccounts
        self.activeStoredAccount = activeStoredAccount
        self.liveSystemAccount = liveSystemAccount
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

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct DefaultCodexAccountReconciler {
    public let storeLoader: @Sendable () throws -> ManagedCodexAccountSet
    public let systemObserver: any CodexSystemAccountObserving
    public let activeSource: CodexActiveSource
    public let baseEnvironment: [String: String]
    public let managedEnvironmentBuilder: @Sendable ([String: String], ManagedCodexAccount) -> [String: String]

    public init(
        storeLoader: @escaping @Sendable () throws -> ManagedCodexAccountSet = {
            try FileManagedCodexAccountStore().loadAccounts()
        },
        systemObserver: any CodexSystemAccountObserving = DefaultCodexSystemAccountObserver(),
        activeSource: CodexActiveSource = .liveSystem,
        baseEnvironment: [String: String],
        managedEnvironmentBuilder: @escaping @Sendable ([String: String], ManagedCodexAccount)
            -> [String: String] = { baseEnvironment, account in
                CodexHomeScope.scopedEnvironment(base: baseEnvironment, codexHome: account.managedHomePath)
            })
    {
        self.storeLoader = storeLoader
        self.systemObserver = systemObserver
        self.activeSource = activeSource
        self.baseEnvironment = baseEnvironment
        self.managedEnvironmentBuilder = managedEnvironmentBuilder
    }

    public func loadSnapshot() -> CodexAccountReconciliationSnapshot {
        let liveSystemAccount = self.loadLiveSystemAccount()

        do {
            let accounts = try self.storeLoader()
            let runtimeAccounts = Dictionary(uniqueKeysWithValues: accounts.accounts.map { account in
                let runtimeAccount = self.loadRuntimeAccount(for: account)
                return (account.id, runtimeAccount)
            })
            let activeStoredAccount: ManagedCodexAccount? = switch self.activeSource {
            case let .managedAccount(id):
                accounts.account(id: id)
            case .liveSystem:
                nil
            }
            let matchingStoredAccountForLiveSystemAccount = liveSystemAccount.flatMap { liveAccount in
                accounts.accounts.first { account in
                    guard let runtimeAccount = runtimeAccounts[account.id] else { return false }
                    return CodexIdentityMatcher.matches(runtimeAccount.identity, self.runtimeIdentity(for: liveAccount))
                }
            }

            return CodexAccountReconciliationSnapshot(
                storedAccounts: accounts.accounts,
                activeStoredAccount: activeStoredAccount,
                liveSystemAccount: liveSystemAccount,
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
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: self.activeSource,
                hasUnreadableAddedAccountStore: true)
        }
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

    private func runtimeIdentity(for liveSystemAccount: ObservedSystemCodexAccount) -> CodexIdentity {
        CodexIdentityMatcher.normalized(
            liveSystemAccount.identity,
            fallbackEmail: liveSystemAccount.email)
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
    }
}
