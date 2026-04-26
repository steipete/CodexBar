import CodexBarCore
import Darwin
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

@MainActor
struct SettingsStoreCodexAccountReconciliationSnapshotLoader: CodexAccountReconciliationSnapshotLoading {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func loadSnapshot() -> CodexAccountReconciliationSnapshot {
        self.settingsStore.codexAccountReconciliationSnapshot
    }
}

struct DefaultCodexAuthMaterialReader: CodexAuthMaterialReading {
    func readAuthData(homeURL: URL) throws -> Data? {
        let authFileURL = CodexAccountPromotionService.authFileURL(for: homeURL)
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            return nil
        }
        return try Data(contentsOf: authFileURL)
    }
}

struct DefaultCodexLiveAuthSwapper: CodexLiveAuthSwapping {
    func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws {
        try FileManager.default.createDirectory(at: liveHomeURL, withIntermediateDirectories: true)

        let liveAuthURL = CodexAccountPromotionService.authFileURL(for: liveHomeURL)
        let stagedAuthURL = liveHomeURL.appendingPathComponent(
            "auth.json.codexbar-staged-\(UUID().uuidString)",
            isDirectory: false)

        do {
            try data.write(to: stagedAuthURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: stagedAuthURL.path)
            try self.renameItem(at: stagedAuthURL, to: liveAuthURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedAuthURL)
            throw error
        }
    }

    private func renameItem(at sourceURL: URL, to destinationURL: URL) throws {
        let sourcePath = sourceURL.path
        let destinationPath = destinationURL.path

        let result = sourcePath.withCString { sourceFS in
            destinationPath.withCString { destinationFS in
                rename(sourceFS, destinationFS)
            }
        }

        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: destinationPath])
        }
    }
}

@MainActor
struct SettingsStoreCodexActiveSourceWriter: CodexActiveSourceWriting {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func writeCodexActiveSource(_ source: CodexActiveSource) {
        self.settingsStore.codexActiveSource = source
    }
}

@MainActor
struct UsageStoreCodexAccountScopedRefresher: CodexAccountScopedRefreshing {
    private let usageStore: UsageStore

    init(usageStore: UsageStore) {
        self.usageStore = usageStore
    }

    func refreshCodexAccountScopedState(allowDisabled: Bool) async {
        await self.usageStore.refreshCodexAccountScopedState(allowDisabled: allowDisabled)
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
}

enum CodexAccountPromotionError: Error, Equatable {
    case targetManagedAccountNotFound
    case targetManagedAccountAuthMissing
    case targetManagedAccountAuthUnreadable
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
    private let identityReader: any ManagedCodexIdentityReading
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let snapshotLoader: any CodexAccountReconciliationSnapshotLoading
    private let authMaterialReader: any CodexAuthMaterialReading
    private let liveAuthSwapper: any CodexLiveAuthSwapping
    private let activeSourceWriter: any CodexActiveSourceWriting
    private let accountScopedRefresher: any CodexAccountScopedRefreshing
    private let baseEnvironment: [String: String]
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        identityReader: any ManagedCodexIdentityReading,
        workspaceResolver: any ManagedCodexWorkspaceResolving = DefaultManagedCodexWorkspaceResolver(),
        snapshotLoader: any CodexAccountReconciliationSnapshotLoading,
        authMaterialReader: any CodexAuthMaterialReading,
        liveAuthSwapper: any CodexLiveAuthSwapping,
        activeSourceWriter: any CodexActiveSourceWriting,
        accountScopedRefresher: any CodexAccountScopedRefreshing,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.identityReader = identityReader
        self.workspaceResolver = workspaceResolver
        self.snapshotLoader = snapshotLoader
        self.authMaterialReader = authMaterialReader
        self.liveAuthSwapper = liveAuthSwapper
        self.activeSourceWriter = activeSourceWriter
        self.accountScopedRefresher = accountScopedRefresher
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
            identityReader: DefaultManagedCodexIdentityReader(),
            workspaceResolver: DefaultManagedCodexWorkspaceResolver(),
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: settingsStore),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            liveAuthSwapper: DefaultCodexLiveAuthSwapper(),
            activeSourceWriter: SettingsStoreCodexActiveSourceWriter(settingsStore: settingsStore),
            accountScopedRefresher: UsageStoreCodexAccountScopedRefresher(usageStore: usageStore),
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

        let targetAuthMaterial = try self.requiredTargetAuthMaterial(from: context.target)
        let preservationPlan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)
        let executionResult = try CodexDisplacedLivePreservationExecutor(
            store: self.store,
            homeFactory: self.homeFactory,
            fileManager: self.fileManager)
            .execute(plan: preservationPlan, context: context)

        do {
            try self.liveAuthSwapper.swapLiveAuthData(targetAuthMaterial.rawData, liveHomeURL: context.live.homeURL)
        } catch {
            throw CodexAccountPromotionError.liveAuthSwapFailed
        }

        self.activeSourceWriter.writeCodexActiveSource(.liveSystem)
        await self.accountScopedRefresher.refreshCodexAccountScopedState(allowDisabled: true)

        return CodexAccountPromotionResult(
            targetManagedAccountID: id,
            outcome: .promoted,
            displacedLiveDisposition: executionResult.displacedLiveDisposition,
            didMutateLiveAuth: true,
            resultingActiveSource: .liveSystem)
    }

    nonisolated static func authFileURL(for homeURL: URL) -> URL {
        homeURL.appendingPathComponent("auth.json", isDirectory: false)
    }

    private func convergedActiveSource(for context: PreparedPromotionContext) -> CodexActiveSource? {
        if let liveAuthIdentity = context.live.authIdentity {
            let targetIdentity = context.target.authIdentity ?? context.target.persistedIdentity
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
            context.snapshot.runtimeIdentity(for: context.target.persisted),
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
