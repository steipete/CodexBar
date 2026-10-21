import Foundation

private struct CodexPreparedImportedAccount {
    package let account: ManagedCodexAccount
    package let homeURL: URL
}

@MainActor
package struct CodexDisplacedLivePreservationExecutor {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let authMaterialReader: any CodexAuthMaterialReading
    private let fileManager: FileManager

    package init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        authMaterialReader: any CodexAuthMaterialReading = DefaultCodexAuthMaterialReader(),
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.authMaterialReader = authMaterialReader
        self.fileManager = fileManager
    }

    package func execute(
        plan: CodexDisplacedLivePreservationPlan,
        context: PreparedPromotionContext) throws
        -> CodexAccountPromotionResult.DisplacedLiveDisposition
    {
        /*
         Safety contract:
         - This executor never swaps live auth. The caller must do that only after success.
         - Import cleanup is best-effort and leaves no orphaned managed home on failure.
         - Refresh/repair may copy auth before store commit, matching current behavior.
         */
        switch plan {
        case .none:
            return .none

        case let .reject(reason):
            throw self.error(for: reason)

        case .importNew:
            let importedAccount = try self.importDisplacedLiveAccount(from: context)
            return try self.commitImportedAccount(
                importedAccount,
                excludingTargetID: context.target.persisted.id)

        case let .refreshExisting(destination, _),
             let .repairExisting(destination, _):
            guard destination.persisted.id != context.target.persisted.id else {
                throw CodexAccountPromotionError.managedStoreCommitFailed
            }

            let refreshed = try self.refreshExistingManagedAccount(destination, from: context)
            return .alreadyManaged(managedAccountID: refreshed.id)
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
        guard CodexCredentialFileAccess.permits(CodexAuthFingerprint.authFileURL(homePath: importedHomeURL.path)) else {
            throw CodexAccountPromotionError.displacedLiveImportFailed
        }
        let importedAccountID = UUID(uuidString: importedHomeURL.lastPathComponent) ?? UUID()

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
                    authFingerprint: CodexAuthFingerprint.fingerprint(data: liveAuthMaterial.rawData),
                    managedHomePath: importedHomeURL.path,
                    createdAt: now,
                    updatedAt: now,
                    lastAuthenticatedAt: now),
                homeURL: importedHomeURL)
        } catch {
            try? self.removeManagedHomeIfSafe(importedHomeURL)
            throw error as? CodexAccountPromotionError ?? .displacedLiveImportFailed
        }
    }

    private func commitImportedAccount(
        _ importedAccount: CodexPreparedImportedAccount,
        excludingTargetID: UUID) throws
        -> CodexAccountPromotionResult.DisplacedLiveDisposition
    {
        do {
            let latestManagedAccounts = try self.store.loadAccounts()
            try self.store.storeAccounts(ManagedCodexAccountSet(
                version: latestManagedAccounts.version,
                accounts: latestManagedAccounts.accounts + [importedAccount.account]))
            return try self.resolveImportedAccountAfterCommit(
                importedAccount,
                excludingTargetID: excludingTargetID)
        } catch {
            try? self.removeManagedHomeIfSafe(importedAccount.homeURL)
            throw error as? CodexAccountPromotionError ?? .managedStoreCommitFailed
        }
    }

    private func resolveImportedAccountAfterCommit(
        _ importedAccount: CodexPreparedImportedAccount,
        excludingTargetID: UUID) throws
        -> CodexAccountPromotionResult.DisplacedLiveDisposition
    {
        let persistedManagedAccounts = try self.store.loadAccounts()
        if persistedManagedAccounts.account(id: importedAccount.account.id) != nil {
            return .imported(managedAccountID: importedAccount.account.id)
        }

        let candidates = ManagedCodexAccountSet(
            version: persistedManagedAccounts.version,
            accounts: persistedManagedAccounts.accounts.filter { $0.id != excludingTargetID })
        guard let existingManagedAccount = candidates.account(
            email: importedAccount.account.email,
            providerAccountID: importedAccount.account.effectiveWorkspaceAccountID)
        else {
            throw CodexAccountPromotionError.managedStoreCommitFailed
        }
        try self.validateDestinationAuth(
            homeURL: URL(fileURLWithPath: existingManagedAccount.managedHomePath, isDirectory: true),
            identity: CodexIdentityResolver.resolve(
                accountId: importedAccount.account.providerAccountID, email: importedAccount.account.email),
            email: importedAccount.account.email,
            allowsUnreadable: true)

        let repairedManagedAccount = ManagedCodexAccount(
            id: existingManagedAccount.id,
            email: importedAccount.account.email,
            providerAccountID: importedAccount.account.providerAccountID,
            workspaceLabel: importedAccount.account.workspaceLabel,
            workspaceAccountID: importedAccount.account.workspaceAccountID,
            authFingerprint: importedAccount.account.authFingerprint,
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
        let replacedHomePath = existingManagedAccount.managedHomePath
        let replacedHomeStillReferenced = persistedManagedAccounts.accounts.contains {
            $0.id != existingManagedAccount.id && $0.managedHomePath == replacedHomePath
        }
        if replacedHomePath != importedAccount.homeURL.path, replacedHomeStillReferenced == false {
            try? self.removeManagedHomeIfSafe(
                URL(fileURLWithPath: replacedHomePath, isDirectory: true))
        }

        return .alreadyManaged(managedAccountID: existingManagedAccount.id)
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
                authFingerprint: CodexAuthFingerprint.fingerprint(data: liveAuthMaterial.rawData),
                managedHomePath: persistedManagedAccount.managedHomePath,
                createdAt: persistedManagedAccount.createdAt,
                updatedAt: now,
                lastAuthenticatedAt: now)

            let refreshedHomeURL = URL(fileURLWithPath: persistedManagedAccount.managedHomePath, isDirectory: true)
            guard CodexCredentialFileAccess.permits(CodexAuthFingerprint.authFileURL(homePath: refreshedHomeURL.path))
            else {
                throw CodexAccountPromotionError.displacedLiveImportFailed
            }
            do {
                try self.homeFactory.validateManagedHomeForDeletion(refreshedHomeURL)
            } catch {
                throw CodexAccountPromotionError.displacedLiveImportFailed
            }

            try self.validateDestinationAuth(
                homeURL: refreshedHomeURL,
                identity: liveAuthIdentity.identity,
                email: liveAuthIdentity.email,
                allowsUnreadable: destination.authIdentity == nil)
            try self.fileManager.createDirectory(at: refreshedHomeURL, withIntermediateDirectories: true)
            try self.writeManagedAuthData(liveAuthMaterial.rawData, to: refreshedHomeURL)
            // Verify the preserved bytes before publishing their fingerprint in the account store.
            guard (try? self.authMaterialReader.readAuthData(homeURL: refreshedHomeURL)) == liveAuthMaterial
                .rawData
            else {
                throw CodexAccountPromotionError.displacedLiveManagedAccountConflict
            }
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

    /// External Codex writers do not share our lock; validate every destination again before replacing it.
    private func validateDestinationAuth(
        homeURL: URL,
        identity: CodexIdentity,
        email: String?,
        allowsUnreadable: Bool) throws
    {
        let authData: Data?
        do {
            authData = try self.authMaterialReader.readAuthData(homeURL: homeURL)
        } catch {
            throw CodexAccountPromotionError.displacedLiveManagedAccountConflict
        }
        guard let authData else { return }
        guard (try? CodexOAuthCredentialsStore.parse(data: authData)) != nil,
              let authIdentity = try? PreparedPromotionContextBuilder.runtimeAccount(from: authData)
        else {
            if allowsUnreadable { return }
            throw CodexAccountPromotionError.displacedLiveManagedAccountConflict
        }
        guard CodexIdentityMatcher.matches(
            authIdentity.identity,
            lhsEmail: authIdentity.email,
            identity,
            rhsEmail: email)
        else {
            throw CodexAccountPromotionError.displacedLiveManagedAccountConflict
        }
    }

    private func writeManagedAuthData(_ data: Data, to homeURL: URL) throws {
        let authFileURL = CodexAuthFingerprint.authFileURL(homePath: homeURL.path)
        guard CodexCredentialFileAccess.permits(authFileURL) else { throw CodexOAuthCredentialsError.notFound }
        try CredentialFileWriter.writePrivate(data, to: authFileURL)
    }

    private func removeManagedHomeIfSafe(_ homeURL: URL) throws {
        guard CodexCredentialFileAccess.permits(CodexAuthFingerprint.authFileURL(homePath: homeURL.path))
        else { return }
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
    }
}
