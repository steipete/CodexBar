import CodexBarCore
import Foundation
import Observation

/// A manual, in-memory transaction. Ordinary usage refreshes never call this store's loader.
@MainActor
@Observable
final class CodexRemoteCostStore {
    typealias Loader = @Sendable (
        CodexCombinedCostRequest,
        @escaping @Sendable (CodexCombinedCostPhase) async -> Void) async throws -> CodexCombinedCostResult

    var enabled: Bool {
        didSet {
            self.defaults.set(self.enabled, forKey: "codexRemoteCostEnabled")
            if self.enabled != oldValue { self.invalidate() }
        }
    }

    var host: String {
        didSet {
            self.defaults.set(self.host, forKey: "codexRemoteCostHost")
            if self.host != oldValue { self.invalidate() }
        }
    }

    var home: String {
        didSet {
            self.defaults.set(self.home, forKey: "codexRemoteCostHome")
            if self.home != oldValue { self.invalidate() }
        }
    }

    private(set) var consentGranted: Bool
    private(set) var phase: CodexCombinedCostPhase?
    private(set) var result: CodexCombinedCostResult?
    private(set) var resultContext: CodexRemoteCostContext?
    private(set) var errorMessage: String?
    private(set) var cleanupRequired = false
    private(set) var isRunning = false
    private(set) var isCheckingConfiguration = false
    private(set) var needsRefresh = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let cleanup: @Sendable () async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeContext: CodexRemoteCostContext?

    init(
        defaults: UserDefaults,
        loader: @escaping Loader,
        cleanup: @escaping @Sendable () async throws -> Void)
    {
        self.defaults = defaults
        self.loader = loader
        self.cleanup = cleanup
        self.enabled = defaults.bool(forKey: "codexRemoteCostEnabled")
        self.host = defaults.string(forKey: "codexRemoteCostHost") ?? ""
        self.home = defaults.string(forKey: "codexRemoteCostHome") ?? "~/.codex"
        self.consentGranted = defaults.bool(forKey: "codexRemoteCostRawLogConsentV1")
    }

    var source: CodexRemoteLogSource {
        CodexRemoteLogSource(host: self.host, home: self.home)
    }

    func grantConsent() {
        self.consentGranted = true
        self.defaults.set(true, forKey: "codexRemoteCostRawLogConsentV1")
    }

    func invalidate() {
        self.generation &+= 1
        self.task?.cancel()
        if self.isRunning {
            self.phase = nil
            self.isCheckingConfiguration = false
        }
        self.result = nil
        self.resultContext = nil
        self.needsRefresh = true
        if !self.cleanupRequired { self.errorMessage = nil }
    }

    func reconcile(_ context: CodexRemoteCostContext) {
        if let previous = self.resultContext ?? self.activeContext, previous != context {
            if self.isRunning, self.activeContext == nil {
                // The newly requested initial context supersedes an older frozen result, not its own request.
                self.result = nil
                self.resultContext = nil
                self.needsRefresh = true
            } else {
                self.invalidate()
                self.activeContext = nil
            }
        }
    }

    func refresh(
        context: CodexRemoteCostContext,
        currentContext: @escaping @MainActor () async throws -> CodexRemoteCostContext)
    {
        guard self.canRefresh, context.isAmbient, self.validate(context) else { return }
        self.refresh(contextProvider: { context }, currentContext: currentContext)
    }

    /// Owns both context checks so cancellation drains configuration work as well as the remote transaction.
    func refresh(
        contextProvider: @escaping @MainActor () async throws -> CodexRemoteCostContext,
        currentContext: @escaping @MainActor () async throws -> CodexRemoteCostContext)
    {
        guard self.canRefresh else { return }
        self.generation &+= 1
        let generation = self.generation
        self.isRunning = true
        self.isCheckingConfiguration = true
        self.errorMessage = nil
        let loader = self.loader
        let cleanup = self.cleanup
        self.task = Task { [weak self] in
            do {
                let context = try await contextProvider()
                guard let self else { return }
                guard self.generation == generation, !Task.isCancelled, self.enabled,
                      context.isAmbient, self.validate(context)
                else { self.finish(); return }
                self.reconcile(context)
                self.activeContext = context
                self.isCheckingConfiguration = false
                self.phase = .cleaning
                try await cleanup()
                try Task.checkCancellation()
                self.setPhase(.fetching, generation: generation)
                let result = try await loader(context.request) { [weak self] phase in
                    await self?.setPhase(phase, generation: generation)
                }
                self.isCheckingConfiguration = true
                let liveContext = try await currentContext()
                guard self.generation == generation, !Task.isCancelled,
                      self.enabled, context == liveContext
                else {
                    self.invalidate()
                    self.finish()
                    return
                }
                // The service has cleaned raw artifacts, and a new asynchronous revision read has completed.
                self.result = result
                self.resultContext = context
                self.needsRefresh = false
                self.finish()
            } catch {
                guard let self else { return }
                let cleanupFailure = (error as? CodexRemoteLogError)?.isCleanupFailure == true
                if cleanupFailure || self.generation == generation {
                    self.result = nil
                    self.resultContext = nil
                    self.cleanupRequired = cleanupFailure
                    self.errorMessage = error is CancellationError && !cleanupFailure
                        ? "Server refresh cancelled. Only this Mac is shown."
                        : Self.safeMessage(error)
                }
                self.finish()
            }
        }
    }

    private var canRefresh: Bool {
        self.enabled && self.consentGranted && !self.isRunning && !self.cleanupRequired
    }

    private func validate(_ context: CodexRemoteCostContext) -> Bool {
        guard context.sshRevision != CodexRemoteLogMirror.unavailableConfigurationFingerprint else {
            self.result = nil
            self.resultContext = nil
            self.errorMessage = "SSH configuration cannot be verified. Check that configuration files are readable, " +
                "valid text and within the size limit before refreshing."
            return false
        }
        do {
            try context.source.validate()
            return true
        } catch {
            self.errorMessage = Self.safeMessage(error)
            return false
        }
    }

    func cancel() async {
        self.invalidate()
        let task = self.task
        await task?.value
        if !self.cleanupRequired { self.errorMessage = "Server refresh cancelled. Only this Mac is shown." }
    }

    func shutdown() async {
        self.invalidate()
        await self.task?.value
        if self.cleanupRequired { await self.retryCleanup() }
    }

    func retryCleanup() async {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.phase = .cleaning
        let cleanup = self.cleanup
        self.task = Task { [weak self] in
            do {
                try await cleanup()
                self?.cleanupRequired = false
                self?.errorMessage = nil
            } catch {
                self?.cleanupRequired = true
                self?.errorMessage = Self.safeMessage(error)
            }
            self?.finish()
        }
        await self.task?.value
    }

    func selectedResult(context: CodexRemoteCostContext) -> CodexCombinedCostResult? {
        guard self.enabled, context.isAmbient, self.resultContext == context,
              context.sshRevision != CodexRemoteLogMirror.unavailableConfigurationFingerprint
        else { return nil }
        return self.result
    }

    private func setPhase(_ phase: CodexCombinedCostPhase, generation: UInt64) {
        guard self.generation == generation else { return }
        self.phase = phase
    }

    private func finish() {
        self.isCheckingConfiguration = false
        self.phase = nil
        self.activeContext = nil
        self.isRunning = false
        self.task = nil
    }

    private static func safeMessage(_ error: Error) -> String {
        if let safe = error as? CodexRemoteLogError { return safe.localizedDescription }
        if let safe = error as? CodexCombinedCostError { return safe.localizedDescription }
        return "Server statistics could not be refreshed. Only this Mac is shown."
    }
}

struct CodexRemoteCostContext: Equatable, Sendable {
    let source: CodexRemoteLogSource
    let localCodexHome: URL
    let localScope: String
    let historyDays: Int
    let calendar: Calendar
    let day: Date
    let pricingRevision: String
    let sshRevision: String
    let pricingCacheRoot: URL?
    let localCostCacheRoot: URL?
    let now: Date

    var isAmbient: Bool {
        self.localScope == "codex:ambient"
    }

    var request: CodexCombinedCostRequest {
        CodexCombinedCostRequest(
            source: self.source,
            localCodexHome: self.localCodexHome,
            historyDays: self.historyDays,
            calendar: self.calendar,
            now: self.now,
            pricingCacheRoot: self.pricingCacheRoot,
            localCostCacheRoot: self.localCostCacheRoot)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.localCodexHome == rhs.localCodexHome && lhs.localScope == rhs.localScope &&
            lhs.historyDays == rhs.historyDays && lhs.calendar == rhs.calendar && lhs.day == rhs.day &&
            lhs.pricingRevision == rhs.pricingRevision && lhs.sshRevision == rhs.sshRevision &&
            lhs.pricingCacheRoot == rhs.pricingCacheRoot && lhs.localCostCacheRoot == rhs.localCostCacheRoot
    }
}

struct CodexRemoteCostPresentation: Equatable {
    let title: String
    let detail: String
    let status: String
    let isCombined: Bool

    var lines: [String] {
        [self.title, self.detail, self.status].filter { !$0.isEmpty }
    }
}
