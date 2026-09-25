import CodexBarCore
import Foundation

@MainActor
protocol CodexAccountReconciliationSnapshotLoading {
    func loadSnapshot() -> CodexAccountReconciliationSnapshot
}

protocol CodexAuthMaterialReading: Sendable {
    func readAuthData(homeURL: URL) throws -> Data?
}

protocol CodexLiveAuthSwapping: Sendable {
    func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws
}

@MainActor
protocol CodexActiveSourceWriting {
    func writeCodexActiveSource(_ source: CodexActiveSource)
}

@MainActor
protocol CodexAccountScopedRefreshing {
    func refreshCodexAccountScopedState(allowDisabled: Bool) async
}

extension SettingsStore: CodexAccountReconciliationSnapshotLoading, CodexActiveSourceWriting {
    func loadSnapshot() -> CodexAccountReconciliationSnapshot {
        self.codexAccountReconciliationSnapshot
    }

    func writeCodexActiveSource(_ source: CodexActiveSource) {
        self.codexActiveSource = source
    }
}

extension UsageStore: CodexAccountScopedRefreshing {
    func refreshCodexAccountScopedState(allowDisabled: Bool) async {
        await self.refreshCodexAccountScopedState(allowDisabled: allowDisabled, phaseDidChange: nil)
    }
}

struct DefaultCodexAuthMaterialReader: CodexAuthMaterialReading {
    func readAuthData(homeURL: URL) throws -> Data? {
        let authFileURL = CodexAuthFingerprint.authFileURL(homePath: homeURL.path)
        guard CodexCredentialFileAccess.fileExists(at: authFileURL) else {
            return nil
        }
        return try CodexCredentialFileAccess.read(at: authFileURL)
    }
}

struct DefaultCodexLiveAuthSwapper: CodexLiveAuthSwapping {
    func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws {
        let liveAuthURL = CodexAuthFingerprint.authFileURL(homePath: liveHomeURL.path)
        guard CodexCredentialFileAccess.permits(liveAuthURL) else { throw CodexOAuthCredentialsError.notFound }
        if try CodexCredentialFileAccess.substituteWriteForTesting(at: liveAuthURL) {
            return
        }
        try CodexCredentialFileAccess.createDirectory(forCredentialAt: liveAuthURL)

        try CredentialFileWriter.writePrivate(data, to: liveAuthURL)
    }
}

struct CodexAccountPromotionResult: Equatable {
    enum Outcome: Equatable {
        case promoted
        case convergedNoOp
    }

    enum DisplacedLiveDisposition: Equatable {
        case none
        case alreadyManaged(managedAccountID: UUID)
        case imported(managedAccountID: UUID)
    }

    let targetManagedAccountID: UUID
    let outcome: Outcome
    let displacedLiveDisposition: DisplacedLiveDisposition
    let didMutateLiveAuth: Bool
    let resultingActiveSource: CodexActiveSource
    var daemonRestartNote: String?
}

enum CodexAccountPromotionError: Error, Equatable {
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
}

@MainActor
final class CodexAccountPromotionService {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let snapshotLoader: any CodexAccountReconciliationSnapshotLoading
    private let authMaterialReader: any CodexAuthMaterialReading
    private let liveAuthSwapper: any CodexLiveAuthSwapping
    private let activeSourceWriter: any CodexActiveSourceWriting
    private let accountScopedRefresher: any CodexAccountScopedRefreshing
    private let daemon: CodexAppServerDaemon
    private let baseEnvironment: [String: String]
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        workspaceResolver: any ManagedCodexWorkspaceResolving = DefaultManagedCodexWorkspaceResolver(),
        snapshotLoader: any CodexAccountReconciliationSnapshotLoading,
        authMaterialReader: any CodexAuthMaterialReading,
        liveAuthSwapper: any CodexLiveAuthSwapping,
        activeSourceWriter: any CodexActiveSourceWriting,
        accountScopedRefresher: any CodexAccountScopedRefreshing,
        daemon: CodexAppServerDaemon = CodexAppServerDaemon(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.workspaceResolver = workspaceResolver
        self.snapshotLoader = snapshotLoader
        self.authMaterialReader = authMaterialReader
        self.liveAuthSwapper = liveAuthSwapper
        self.activeSourceWriter = activeSourceWriter
        self.accountScopedRefresher = accountScopedRefresher
        self.daemon = daemon
        self.baseEnvironment = baseEnvironment
        self.fileManager = fileManager
    }

    convenience init(
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
    {
        self.init(
            store: FileManagedCodexAccountStore(fileManager: fileManager),
            homeFactory: ManagedCodexHomeFactory(fileManager: fileManager),
            workspaceResolver: DefaultManagedCodexWorkspaceResolver(),
            snapshotLoader: settingsStore,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            liveAuthSwapper: DefaultCodexLiveAuthSwapper(),
            activeSourceWriter: settingsStore,
            accountScopedRefresher: usageStore,
            baseEnvironment: baseEnvironment,
            fileManager: fileManager)
    }

    func promoteManagedAccount(id: UUID) async throws -> CodexAccountPromotionResult {
        let contextBuilder = PreparedPromotionContextBuilder(
            store: self.store,
            workspaceResolver: self.workspaceResolver,
            snapshotLoader: self.snapshotLoader,
            authMaterialReader: self.authMaterialReader,
            baseEnvironment: self.baseEnvironment,
            fileManager: self.fileManager)
        let context = try await contextBuilder.build(targetID: id)

        if let resultingActiveSource = self.convergedActiveSource(for: context) {
            self.activeSourceWriter.writeCodexActiveSource(resultingActiveSource)
            await self.accountScopedRefresher.refreshCodexAccountScopedState(allowDisabled: true)
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

        do {
            try self.liveAuthSwapper.swapLiveAuthData(targetAuthMaterial.rawData, liveHomeURL: context.live.homeURL)
        } catch {
            throw CodexAccountPromotionError.liveAuthSwapFailed
        }

        self.activeSourceWriter.writeCodexActiveSource(.liveSystem)
        let daemonRestartNote = await self.daemon.restartIfRunning(
            homeURL: context.live.homeURL, environment: self.baseEnvironment)
        await self.accountScopedRefresher.refreshCodexAccountScopedState(allowDisabled: true)

        return CodexAccountPromotionResult(
            targetManagedAccountID: id,
            outcome: .promoted,
            displacedLiveDisposition: executionResult,
            didMutateLiveAuth: true,
            resultingActiveSource: .liveSystem,
            daemonRestartNote: daemonRestartNote)
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
