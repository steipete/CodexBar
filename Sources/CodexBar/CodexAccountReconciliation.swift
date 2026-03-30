import CodexBarCore
import Foundation

struct CodexVisibleAccount: Equatable, Sendable, Identifiable {
    let id: String
    let email: String
    let storedAccountID: UUID?
    let selectionSource: CodexActiveSource
    let isActive: Bool
    let isLive: Bool
    let canReauthenticate: Bool
    let canRemove: Bool
}

struct CodexVisibleAccountProjection: Equatable, Sendable {
    let visibleAccounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
    let liveVisibleAccountID: String?
    let hasUnreadableAddedAccountStore: Bool

    func source(forVisibleAccountID id: String) -> CodexActiveSource? {
        self.visibleAccounts.first { $0.id == id }?.selectionSource
    }
}

struct CodexResolvedActiveSource: Equatable, Sendable {
    let persistedSource: CodexActiveSource
    let resolvedSource: CodexActiveSource

    var requiresPersistenceCorrection: Bool {
        self.persistedSource != self.resolvedSource
    }
}

enum CodexActiveSourceResolver {
    static func resolve(from snapshot: CodexAccountReconciliationSnapshot) -> CodexResolvedActiveSource {
        let persistedSource = snapshot.activeSource
        let resolvedSource: CodexActiveSource = switch persistedSource {
        case .liveSystem:
            .liveSystem
        case let .managedAccount(id):
            if let activeStoredAccount = snapshot.activeStoredAccount {
                self.matchesLiveSystemAccountEmail(
                    storedAccount: activeStoredAccount,
                    liveSystemAccount: snapshot.liveSystemAccount) ? .liveSystem : .managedAccount(id: id)
            } else {
                snapshot.liveSystemAccount != nil ? .liveSystem : .managedAccount(id: id)
            }
        }

        return CodexResolvedActiveSource(
            persistedSource: persistedSource,
            resolvedSource: resolvedSource)
    }

    private static func matchesLiveSystemAccountEmail(
        storedAccount: ManagedCodexAccount,
        liveSystemAccount: ObservedSystemCodexAccount?) -> Bool
    {
        guard let liveSystemAccount else { return false }
        return Self.normalizeEmail(storedAccount.email) == Self.normalizeEmail(liveSystemAccount.email)
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct CodexAccountReconciliationSnapshot: Equatable, Sendable {
    let storedAccounts: [ManagedCodexAccount]
    let activeStoredAccount: ManagedCodexAccount?
    let liveSystemAccount: ObservedSystemCodexAccount?
    let matchingStoredAccountForLiveSystemAccount: ManagedCodexAccount?
    let activeSource: CodexActiveSource
    let hasUnreadableAddedAccountStore: Bool

    static func == (lhs: CodexAccountReconciliationSnapshot, rhs: CodexAccountReconciliationSnapshot) -> Bool {
        lhs.storedAccounts.map(AccountIdentity.init) == rhs.storedAccounts.map(AccountIdentity.init)
            && lhs.activeStoredAccount.map(AccountIdentity.init) == rhs.activeStoredAccount.map(AccountIdentity.init)
            && lhs.liveSystemAccount == rhs.liveSystemAccount
            && lhs.matchingStoredAccountForLiveSystemAccount.map(AccountIdentity.init)
            == rhs.matchingStoredAccountForLiveSystemAccount.map(AccountIdentity.init)
            && lhs.activeSource == rhs.activeSource
            && lhs.hasUnreadableAddedAccountStore == rhs.hasUnreadableAddedAccountStore
    }
}

struct DefaultCodexAccountReconciler {
    let storeLoader: @Sendable () throws -> ManagedCodexAccountSet
    let systemObserver: any CodexSystemAccountObserving
    let activeSource: CodexActiveSource

    init(
        storeLoader: @escaping @Sendable () throws -> ManagedCodexAccountSet = {
            try FileManagedCodexAccountStore().loadAccounts()
        },
        systemObserver: any CodexSystemAccountObserving = DefaultCodexSystemAccountObserver(),
        activeSource: CodexActiveSource = .liveSystem)
    {
        self.storeLoader = storeLoader
        self.systemObserver = systemObserver
        self.activeSource = activeSource
    }

    func loadSnapshot(environment: [String: String]) -> CodexAccountReconciliationSnapshot {
        let liveSystemAccount = self.loadLiveSystemAccount(environment: environment)

        do {
            let accounts = try self.storeLoader()
            let activeStoredAccount: ManagedCodexAccount? = switch self.activeSource {
            case let .managedAccount(id):
                accounts.account(id: id)
            case .liveSystem:
                nil
            }
            let matchingStoredAccountForLiveSystemAccount = liveSystemAccount.flatMap {
                accounts.account(email: $0.email)
            }

            return CodexAccountReconciliationSnapshot(
                storedAccounts: accounts.accounts,
                activeStoredAccount: activeStoredAccount,
                liveSystemAccount: liveSystemAccount,
                matchingStoredAccountForLiveSystemAccount: matchingStoredAccountForLiveSystemAccount,
                activeSource: self.activeSource,
                hasUnreadableAddedAccountStore: false)
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

    func loadVisibleAccounts(environment: [String: String]) -> CodexVisibleAccountProjection {
        CodexVisibleAccountProjection.make(from: self.loadSnapshot(environment: environment))
    }

    private func loadLiveSystemAccount(environment: [String: String]) -> ObservedSystemCodexAccount? {
        do {
            guard let account = try self.systemObserver.loadSystemAccount(environment: environment) else {
                return nil
            }
            let normalizedEmail = Self.normalizeEmail(account.email)
            guard !normalizedEmail.isEmpty else {
                return nil
            }
            return ObservedSystemCodexAccount(
                email: normalizedEmail,
                codexHomePath: account.codexHomePath,
                observedAt: account.observedAt)
        } catch {
            return nil
        }
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension CodexVisibleAccountProjection {
    static func make(from snapshot: CodexAccountReconciliationSnapshot) -> CodexVisibleAccountProjection {
        let resolvedActiveSource = CodexActiveSourceResolver.resolve(from: snapshot).resolvedSource
        var visibleByEmail: [String: CodexVisibleAccount] = [:]

        for storedAccount in snapshot.storedAccounts {
            let normalizedEmail = Self.normalizeVisibleEmail(storedAccount.email)
            visibleByEmail[normalizedEmail] = CodexVisibleAccount(
                id: normalizedEmail,
                email: normalizedEmail,
                storedAccountID: storedAccount.id,
                selectionSource: .managedAccount(id: storedAccount.id),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true)
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            let normalizedEmail = Self.normalizeVisibleEmail(liveSystemAccount.email)
            if let existing = visibleByEmail[normalizedEmail] {
                visibleByEmail[normalizedEmail] = CodexVisibleAccount(
                    id: existing.id,
                    email: existing.email,
                    storedAccountID: existing.storedAccountID,
                    selectionSource: .liveSystem,
                    isActive: existing.isActive,
                    isLive: true,
                    canReauthenticate: existing.canReauthenticate,
                    canRemove: existing.canRemove)
            } else {
                visibleByEmail[normalizedEmail] = CodexVisibleAccount(
                    id: normalizedEmail,
                    email: normalizedEmail,
                    storedAccountID: nil,
                    selectionSource: .liveSystem,
                    isActive: false,
                    isLive: true,
                    canReauthenticate: true,
                    canRemove: false)
            }
        }

        let activeEmail: String? = switch resolvedActiveSource {
        case let .managedAccount(id):
            snapshot.storedAccounts.first { $0.id == id }.map { Self.normalizeVisibleEmail($0.email) }
        case .liveSystem:
            snapshot.liveSystemAccount.map { Self.normalizeVisibleEmail($0.email) }
        }

        if let activeEmail, let current = visibleByEmail[activeEmail] {
            visibleByEmail[activeEmail] = CodexVisibleAccount(
                id: current.id,
                email: current.email,
                storedAccountID: current.storedAccountID,
                selectionSource: current.selectionSource,
                isActive: true,
                isLive: current.isLive,
                canReauthenticate: current.canReauthenticate,
                canRemove: current.canRemove)
        }

        let visibleAccounts = visibleByEmail.values.sorted { lhs, rhs in
            lhs.email < rhs.email
        }

        return CodexVisibleAccountProjection(
            visibleAccounts: visibleAccounts,
            activeVisibleAccountID: visibleAccounts.first { $0.isActive }?.id,
            liveVisibleAccountID: visibleAccounts.first { $0.isLive }?.id,
            hasUnreadableAddedAccountStore: snapshot.hasUnreadableAddedAccountStore)
    }

    private static func normalizeVisibleEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct AccountIdentity: Equatable {
    let id: UUID
    let email: String
    let managedHomePath: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval
    let lastAuthenticatedAt: TimeInterval?

    init(_ account: ManagedCodexAccount) {
        self.id = account.id
        self.email = account.email
        self.managedHomePath = account.managedHomePath
        self.createdAt = account.createdAt
        self.updatedAt = account.updatedAt
        self.lastAuthenticatedAt = account.lastAuthenticatedAt
    }
}
