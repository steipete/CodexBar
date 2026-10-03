import Foundation

@MainActor
package protocol CodexAccountReconciliationSnapshotLoading {
    func loadSnapshot() -> CodexAccountReconciliationSnapshot
}

package protocol CodexAuthMaterialReading: Sendable {
    func readAuthData(homeURL: URL) throws -> Data?
}

package protocol CodexLiveAuthSwapping: Sendable {
    func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws
}

package protocol ManagedCodexHomeProducing: Sendable {
    func makeHomeURL() -> URL
    func validateManagedHomeForDeletion(_ url: URL) throws
}

package protocol ManagedCodexWorkspaceResolving: Sendable {
    func resolveWorkspaceIdentity(homePath: String, providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    func availableWorkspaceIdentities(homePath: String) async -> [CodexOpenAIWorkspaceIdentity]
}

extension ManagedCodexWorkspaceResolving {
    package func availableWorkspaceIdentities(homePath _: String) async -> [CodexOpenAIWorkspaceIdentity] { [] }
}

package struct DefaultCodexAuthMaterialReader: CodexAuthMaterialReading {
    package init() {}
    package func readAuthData(homeURL: URL) throws -> Data? {
        let authFileURL = CodexAuthFingerprint.authFileURL(homePath: homeURL.path)
        guard CodexCredentialFileAccess.fileExists(at: authFileURL) else {
            return nil
        }
        return try CodexCredentialFileAccess.read(at: authFileURL)
    }
}

package struct DefaultCodexLiveAuthSwapper: CodexLiveAuthSwapping {
    package init() {}
    package func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws {
        let liveAuthURL = CodexAuthFingerprint.authFileURL(homePath: liveHomeURL.path)
        guard CodexCredentialFileAccess.permits(liveAuthURL) else { throw CodexOAuthCredentialsError.notFound }
        if try CodexCredentialFileAccess.substituteWriteForTesting(at: liveAuthURL) {
            return
        }
        try CodexCredentialFileAccess.createDirectory(forCredentialAt: liveAuthURL)

        try CredentialFileWriter.writePrivate(data, to: liveAuthURL)
    }
}

package struct CodexAccountPromotionResult: Equatable {
    package enum Outcome: Equatable {
        case promoted
        case convergedNoOp
    }

    package enum DisplacedLiveDisposition: Equatable {
        case none
        case alreadyManaged(managedAccountID: UUID)
        case imported(managedAccountID: UUID)
    }

    package let targetManagedAccountID: UUID
    package let outcome: Outcome
    package let displacedLiveDisposition: DisplacedLiveDisposition
    package let didMutateLiveAuth: Bool
    package let resultingActiveSource: CodexActiveSource
    package var daemonRestartNote: String?
}

package enum CodexAccountPromotionError: Error, Equatable {
    case targetManagedAccountNotFound
    case targetManagedAccountAuthMissing
    case targetManagedAccountAuthUnreadable
    case targetManagedAccountWorkspaceDiffersFromAuthDefault
    case liveAccountUnreadable
    case liveAccountMissingIdentityForPreservation
    case liveAccountAPIKeyOnlyUnsupported
    case displacedLiveManagedAccountConflict
    case displacedLiveImportFailed
    case managedStoreCommitFailed
    case liveAuthSwapFailed
    case liveAuthChangedDuringPromotion
}

@MainActor
package final class CodexAccountPromotionTransaction {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let snapshotLoader: any CodexAccountReconciliationSnapshotLoading
    private let authMaterialReader: any CodexAuthMaterialReading
    private let liveAuthSwapper: any CodexLiveAuthSwapping
    @ProcessEnvironment private var baseEnvironment: [String: String]
    private let fileManager: FileManager

    package init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        workspaceResolver: any ManagedCodexWorkspaceResolving,
        snapshotLoader: any CodexAccountReconciliationSnapshotLoading,
        authMaterialReader: any CodexAuthMaterialReading,
        liveAuthSwapper: any CodexLiveAuthSwapping,
        baseEnvironment: [String: String],
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.workspaceResolver = workspaceResolver
        self.snapshotLoader = snapshotLoader
        self.authMaterialReader = authMaterialReader
        self.liveAuthSwapper = liveAuthSwapper
        self.baseEnvironment = baseEnvironment
        self.fileManager = fileManager
    }

    package func promoteManagedAccount(id: UUID) async throws -> CodexAccountPromotionResult {
        try await ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            try await self.promoteLocked(id: id)
        }
    }

    private func promoteLocked(id: UUID) async throws -> CodexAccountPromotionResult {
        let contextBuilder = PreparedPromotionContextBuilder(
            store: self.store,
            workspaceResolver: self.workspaceResolver,
            snapshotLoader: self.snapshotLoader,
            authMaterialReader: self.authMaterialReader,
            baseEnvironment: self.baseEnvironment,
            fileManager: self.fileManager)
        let context = try await contextBuilder.build(targetID: id)

        if let resultingActiveSource = self.convergedActiveSource(for: context) {
            return CodexAccountPromotionResult(
                targetManagedAccountID: id,
                outcome: .convergedNoOp,
                displacedLiveDisposition: .none,
                didMutateLiveAuth: false,
                resultingActiveSource: resultingActiveSource)
        }

        guard !context.target.selectedWorkspaceDiffersFromAuthDefault else {
            throw CodexAccountPromotionError.targetManagedAccountWorkspaceDiffersFromAuthDefault
        }

        let targetAuthMaterial = try self.requiredTargetAuthMaterial(from: context.target)
        let preservationPlan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)
        let executionResult = try CodexDisplacedLivePreservationExecutor(
            store: self.store,
            homeFactory: self.homeFactory,
            authMaterialReader: self.authMaterialReader,
            fileManager: self.fileManager)
            .execute(plan: preservationPlan, context: context)

        let expectedLiveData: Data? = switch context.live.homeState {
        case .missing: nil
        case .unreadable: nil
        case let .apiKeyOnly(material), let .readable(material): material.rawData
        }
        guard try self.authMaterialReader.readAuthData(homeURL: context.live.homeURL) == expectedLiveData else {
            throw CodexAccountPromotionError.liveAuthChangedDuringPromotion
        }
        do {
            try self.liveAuthSwapper.swapLiveAuthData(targetAuthMaterial.rawData, liveHomeURL: context.live.homeURL)
        } catch {
            throw CodexAccountPromotionError.liveAuthSwapFailed
        }

        return CodexAccountPromotionResult(
            targetManagedAccountID: id,
            outcome: .promoted,
            displacedLiveDisposition: executionResult,
            didMutateLiveAuth: true,
            resultingActiveSource: .liveSystem,
            daemonRestartNote: nil)
    }

    private func convergedActiveSource(for context: PreparedPromotionContext) -> CodexActiveSource? {
        if let liveAuthIdentity = context.live.authIdentity {
            let targetIdentity = context.target.remoteIdentity
            guard CodexIdentityMatcher.matches(
                targetIdentity.identity,
                lhsEmail: targetIdentity.email,
                liveAuthIdentity.identity,
                rhsEmail: liveAuthIdentity.email)
            else {
                return nil
            }

            if liveAuthIdentity.email != nil {
                return .liveSystem
            }

            if liveAuthIdentity.providerAccountID != nil {
                return .managedAccount(id: context.target.persisted.id)
            }

            return nil
        }

        guard let liveSystemAccount = context.snapshot.liveSystemAccount else {
            return nil
        }

        guard CodexIdentityMatcher.matches(
            context.snapshot.managedRemoteIdentity(for: context.target.persisted),
            lhsEmail: context.snapshot.runtimeEmail(for: context.target.persisted),
            context.snapshot.runtimeIdentity(for: liveSystemAccount),
            rhsEmail: liveSystemAccount.email)
        else {
            return nil
        }

        return .liveSystem
    }

    private func requiredTargetAuthMaterial(from target: PreparedStoredManagedAccount) throws -> PreparedAuthMaterial {
        switch target.homeState {
        case let .readable(authMaterial):
            guard authMaterial.authIdentity.email != nil else {
                throw CodexAccountPromotionError.targetManagedAccountAuthUnreadable
            }
            return authMaterial
        case .missing:
            throw CodexAccountPromotionError.targetManagedAccountAuthMissing
        case .unreadable:
            throw CodexAccountPromotionError.targetManagedAccountAuthUnreadable
        }
    }
}

extension CodexAccountPromotionError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .targetManagedAccountNotFound: "The selected managed account no longer exists."
        case .targetManagedAccountAuthMissing, .targetManagedAccountAuthUnreadable:
            "The selected managed account has missing or unreadable authentication."
        case .targetManagedAccountWorkspaceDiffersFromAuthDefault:
            "The selected workspace differs from the saved authentication default."
        case .liveAuthChangedDuringPromotion: "System authentication changed during promotion. Try again."
        case .liveAccountUnreadable, .liveAccountMissingIdentityForPreservation, .liveAccountAPIKeyOnlyUnsupported:
            "Cannot safely preserve the current system authentication."
        case .displacedLiveManagedAccountConflict: "Conflicting managed accounts prevent safe preservation."
        case .displacedLiveImportFailed, .managedStoreCommitFailed: "Could not preserve the current system account."
        case .liveAuthSwapFailed: "Could not atomically replace system authentication."
        }
    }
}
