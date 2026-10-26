import CodexBarCore
import Foundation

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

@MainActor
final class CodexAccountPromotionService {
    private let transaction: CodexAccountPromotionTransaction
    private let activeSourceWriter: any CodexActiveSourceWriting
    private let accountScopedRefresher: any CodexAccountScopedRefreshing
    private let daemon: CodexAppServerDaemon
    @ProcessEnvironment private var baseEnvironment: [String: String]
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
        self.transaction = CodexAccountPromotionTransaction(
            store: store,
            homeFactory: homeFactory,
            workspaceResolver: workspaceResolver,
            snapshotLoader: snapshotLoader,
            authMaterialReader: authMaterialReader,
            liveAuthSwapper: liveAuthSwapper,
            baseEnvironment: baseEnvironment,
            fileManager: fileManager)
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
        var result = try await self.transaction.promoteManagedAccount(id: id)
        self.activeSourceWriter.writeCodexActiveSource(result.resultingActiveSource)
        if result.didMutateLiveAuth {
            let home = CodexHomeScope.ambientHomeURL(env: self.baseEnvironment, fileManager: self.fileManager)
            result.daemonRestartNote = await self.daemon.restartIfRunning(
                homeURL: home,
                environment: self.baseEnvironment)
        }
        await self.accountScopedRefresher.refreshCodexAccountScopedState(allowDisabled: true)
        return result
    }
}
