import CodexBarCore
import Foundation

private struct CodexPreparedImportedAccount {
    let account: ManagedCodexAccount
    let homeURL: URL
}

struct CodexDisplacedLivePreservationExecutionResult: Equatable {
    let displacedLiveDisposition: CodexAccountPromotionResult.DisplacedLiveDisposition
}

@MainActor
struct CodexDisplacedLivePreservationExecutor {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.fileManager = fileManager
    }

    func execute(
        plan: CodexDisplacedLivePreservationPlan,
        context: PreparedPromotionContext) throws
        -> CodexDisplacedLivePreservationExecutionResult
    {
        /*
         Safety contract:
         - This executor never swaps live auth. The caller must do that only after success.
         - Import cleanup is best-effort and leaves no orphaned managed home on failure.
         - Refresh/repair may copy auth before store commit, matching current behavior.
         */
        switch plan {
        case .none:
            return CodexDisplacedLivePreservationExecutionResult(displacedLiveDisposition: .none)

        case let .reject(reason):
            throw self.error(for: reason)

        case .importNew:
            let importedAccount = try self.importDisplacedLiveAccount(from: context)
            return try self.commitImportedAccount(importedAccount)

        case let .refreshExisting(destination, _),
             let .repairExisting(destination, _):
            guard destination.persisted.id != context.target.persisted.id else {
                throw CodexAccountPromotionError.managedStoreCommitFailed
            }

            let refreshed = try self.refreshExistingManagedAccount(destination, from: context)
            return CodexDisplacedLivePreservationExecutionResult(
                displacedLiveDisposition: .alreadyManaged(managedAccountID: refreshed.id))
        }
    }

    private func error(for reason: CodexDisplacedLivePreservationRejectReason) -> CodexAccountPromotionError {
        switch reason {
        case .liveUnreadable:
            .liveAccountUnreadable
        case .liveAPIKeyOnlyUnsupported:
            .liveAccountAPIKeyOnlyUnsupported
        case .liveIdentityMissingForPreservation:
            .liveAccountMissingIdentityForPreservation
        case .conflictingReadableManagedHome:
            .displacedLiveManagedAccountConflict
        }
    }

    private func importDisplacedLiveAccount(
        from context: PreparedPromotionContext) throws
        -> CodexPreparedImportedAccount
    {
        guard case let .readable(liveAuthMaterial) = context.live.homeState else {
            throw CodexAccountPromotionError.displacedLiveImportFailed
        }

        let importedHomeURL = self.homeFactory.makeHomeURL()
        let importedAccountID = Self.accountID(for: importedHomeURL)

        do {
            try self.fileManager.createDirectory(at: importedHomeURL, withIntermediateDirectories: true)
            try self.writeManagedAuthData(liveAuthMaterial.rawData, to: importedHomeURL)

            guard let liveAuthIdentity = context.live.authIdentity,
                  let email = liveAuthIdentity.email,
                  liveAuthIdentity.identity != .unresolved
            else {
                throw CodexAccountPromotionError.liveAccountMissingIdentityForPreservation
            }

            let now = Date().timeIntervalSince1970
            return CodexPreparedImportedAccount(
                account: ManagedCodexAccount(
                    id: importedAccountID,
                    email: email,
                    providerAccountID: liveAuthIdentity.providerAccountID,
                    workspaceLabel: liveAuthIdentity.workspaceLabel,
                    workspaceAccountID: liveAuthIdentity.workspaceAccountID,
                    managedHomePath: importedHomeURL.path,
                    createdAt: now,
                    updatedAt: now,
                    lastAuthenticatedAt: now),
                homeURL: importedHomeURL)
        } catch let error as CodexAccountPromotionError {
            try? self.removeManagedHomeIfSafe(importedHomeURL)
            throw error
        } catch {
            try? self.removeManagedHomeIfSafe(importedHomeURL)
            throw CodexAccountPromotionError.displacedLiveImportFailed
        }
    }

    private func commitImportedAccount(_ importedAccount: CodexPreparedImportedAccount) throws
        -> CodexDisplacedLivePreservationExecutionResult
    {
        do {
            let latestManagedAccounts = try self.store.loadAccounts()
            try self.store.storeAccounts(ManagedCodexAccountSet(
                version: latestManagedAccounts.version,
                accounts: latestManagedAccounts.accounts + [importedAccount.account]))
            return try self.resolveImportedAccountAfterCommit(importedAccount)
        } catch let error as CodexAccountPromotionError {
            try? self.removeManagedHomeIfSafe(importedAccount.homeURL)
            throw error
        } catch {
            try? self.removeManagedHomeIfSafe(importedAccount.homeURL)
            throw CodexAccountPromotionError.managedStoreCommitFailed
        }
    }

    private func resolveImportedAccountAfterCommit(_ importedAccount: CodexPreparedImportedAccount) throws
        -> CodexDisplacedLivePreservationExecutionResult
    {
        let persistedManagedAccounts = try self.store.loadAccounts()
        if persistedManagedAccounts.account(id: importedAccount.account.id) != nil {
            return CodexDisplacedLivePreservationExecutionResult(
                displacedLiveDisposition: .imported(managedAccountID: importedAccount.account.id))
        }

        guard let existingManagedAccount = self.repairDestination(
            in: persistedManagedAccounts,
            for: importedAccount.account)
        else {
            throw CodexAccountPromotionError.managedStoreCommitFailed
        }

        let repairedManagedAccount = ManagedCodexAccount(
            id: existingManagedAccount.id,
            email: importedAccount.account.email,
            providerAccountID: importedAccount.account.providerAccountID,
            workspaceLabel: importedAccount.account.workspaceLabel,
            workspaceAccountID: importedAccount.account.workspaceAccountID,
            managedHomePath: importedAccount.homeURL.path,
            createdAt: existingManagedAccount.createdAt,
            updatedAt: importedAccount.account.updatedAt,
            lastAuthenticatedAt: importedAccount.account.lastAuthenticatedAt)
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: persistedManagedAccounts.version,
            accounts: persistedManagedAccounts.accounts.map { account in
                guard account.id == existingManagedAccount.id else { return account }
                return repairedManagedAccount
            }))
        if existingManagedAccount.managedHomePath != importedAccount.homeURL.path {
            try? self.removeManagedHomeIfSafe(
                URL(fileURLWithPath: existingManagedAccount.managedHomePath, isDirectory: true))
        }

        return CodexDisplacedLivePreservationExecutionResult(
            displacedLiveDisposition: .alreadyManaged(managedAccountID: existingManagedAccount.id))
    }

    private func repairDestination(
        in persistedManagedAccounts: ManagedCodexAccountSet,
        for importedAccount: ManagedCodexAccount) -> ManagedCodexAccount?
    {
        if let providerAccountID = importedAccount.providerAccountID {
            return persistedManagedAccounts.account(
                email: importedAccount.email,
                providerAccountID: providerAccountID)
        }

        let normalizedEmail = importedAccount.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return persistedManagedAccounts.accounts.first {
            $0.email == normalizedEmail && $0.providerAccountID == nil
        }
    }

    private func refreshExistingManagedAccount(
        _ destination: PreparedStoredManagedAccount,
        from context: PreparedPromotionContext) throws
        -> ManagedCodexAccount
    {
        guard case let .readable(liveAuthMaterial) = context.live.homeState else {
            throw CodexAccountPromotionError.managedStoreCommitFailed
        }
        guard let liveAuthIdentity = context.live.authIdentity else {
            throw CodexAccountPromotionError.liveAccountMissingIdentityForPreservation
        }

        do {
            let latestManagedAccounts = try self.store.loadAccounts()
            guard let persistedManagedAccount = latestManagedAccounts.account(id: destination.persisted.id) else {
                throw CodexAccountPromotionError.managedStoreCommitFailed
            }

            let email = liveAuthIdentity.email
                ?? (liveAuthIdentity.providerAccountID != nil ? persistedManagedAccount.email : nil)
            guard let email, liveAuthIdentity.identity != .unresolved else {
                throw CodexAccountPromotionError.liveAccountMissingIdentityForPreservation
            }

            let now = Date().timeIntervalSince1970
            let refreshedManagedAccount = ManagedCodexAccount(
                id: persistedManagedAccount.id,
                email: email,
                providerAccountID: liveAuthIdentity.providerAccountID ?? persistedManagedAccount.providerAccountID,
                workspaceLabel: liveAuthIdentity.workspaceLabel ?? persistedManagedAccount.workspaceLabel,
                workspaceAccountID: liveAuthIdentity.workspaceAccountID ?? persistedManagedAccount.workspaceAccountID,
                managedHomePath: persistedManagedAccount.managedHomePath,
                createdAt: persistedManagedAccount.createdAt,
                updatedAt: now,
                lastAuthenticatedAt: now)

            let refreshedHomeURL = URL(fileURLWithPath: persistedManagedAccount.managedHomePath, isDirectory: true)
            do {
                try self.homeFactory.validateManagedHomeForDeletion(refreshedHomeURL)
            } catch {
                throw CodexAccountPromotionError.displacedLiveImportFailed
            }

            try self.fileManager.createDirectory(at: refreshedHomeURL, withIntermediateDirectories: true)
            try self.writeManagedAuthData(liveAuthMaterial.rawData, to: refreshedHomeURL)
            try self.store.storeAccounts(ManagedCodexAccountSet(
                version: latestManagedAccounts.version,
                accounts: latestManagedAccounts.accounts.map { account in
                    guard account.id == persistedManagedAccount.id else { return account }
                    return refreshedManagedAccount
                }))
            return refreshedManagedAccount
        } catch let error as CodexAccountPromotionError {
            throw error
        } catch {
            throw CodexAccountPromotionError.managedStoreCommitFailed
        }
    }

    private func writeManagedAuthData(_ data: Data, to homeURL: URL) throws {
        let authFileURL = CodexAccountPromotionService.authFileURL(for: homeURL)
        try data.write(to: authFileURL, options: .atomic)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: authFileURL.path)
    }

    private func removeManagedHomeIfSafe(_ homeURL: URL) throws {
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
    }

    private static func accountID(for homeURL: URL) -> UUID {
        UUID(uuidString: homeURL.lastPathComponent) ?? UUID()
    }
}
