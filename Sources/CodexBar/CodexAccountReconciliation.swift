import CodexBarCore
import Foundation

struct CodexVisibleAccount: Equatable, Sendable, Identifiable {
    let id: String
    let email: String
    let storedAccountID: UUID?
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
        var visibleByEmail: [String: CodexVisibleAccount] = [:]

        for storedAccount in snapshot.storedAccounts {
            visibleByEmail[storedAccount.email] = CodexVisibleAccount(
                id: storedAccount.email,
                email: storedAccount.email,
                storedAccountID: storedAccount.id,
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true)
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            if let existing = visibleByEmail[liveSystemAccount.email] {
                visibleByEmail[liveSystemAccount.email] = CodexVisibleAccount(
                    id: existing.id,
                    email: existing.email,
                    storedAccountID: existing.storedAccountID,
                    isActive: existing.isActive,
                    isLive: true,
                    canReauthenticate: existing.canReauthenticate,
                    canRemove: existing.canRemove)
            } else {
                visibleByEmail[liveSystemAccount.email] = CodexVisibleAccount(
                    id: liveSystemAccount.email,
                    email: liveSystemAccount.email,
                    storedAccountID: nil,
                    isActive: false,
                    isLive: true,
                    canReauthenticate: true,
                    canRemove: false)
            }
        }

        let activeEmail: String? = switch snapshot.activeSource {
        case let .managedAccount(id):
            snapshot.storedAccounts.first { $0.id == id }?.email
        case .liveSystem:
            snapshot.liveSystemAccount?.email
        }

        if let activeEmail, let current = visibleByEmail[activeEmail] {
            visibleByEmail[activeEmail] = CodexVisibleAccount(
                id: current.id,
                email: current.email,
                storedAccountID: current.storedAccountID,
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
