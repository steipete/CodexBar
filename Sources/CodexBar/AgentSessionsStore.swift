import CodexBarCore
import Foundation
import Observation

struct AgentSessionRefreshGate {
    private(set) var generation = 0
    private(set) var isInFlight = false
    private(set) var isPending = false

    mutating func settingsDidChange() {
        self.generation += 1
        self.isPending = self.isInFlight
    }

    mutating func begin() -> Int? {
        guard !self.isInFlight else {
            return nil
        }
        self.isInFlight = true
        self.isPending = false
        return self.generation
    }

    mutating func finish(generation: Int) -> (shouldPublish: Bool, shouldRetry: Bool) {
        self.isInFlight = false
        let outcome = (generation == self.generation, self.isPending)
        self.isPending = false
        return outcome
    }
}

typealias AgentSessionRemoteRefreshGate = AgentSessionRefreshGate

@MainActor
@Observable
final class AgentSessionsStore {
    typealias LocalScan = @Sendable (_ includeFileOnlySessions: Bool) async -> [AgentSession]
    typealias RemoteHostDiscovery = @Sendable () async -> [String]
    typealias RemoteFetch = @Sendable (_ hosts: [String]) async -> [RemoteSessionHostResult]
    typealias PeriodicSleep = @Sendable (_ duration: Duration) async throws -> Void

    struct SchedulerState: Equatable {
        let isStarted: Bool
        let hasLocalPeriodicTask: Bool
        let hasRemotePeriodicTask: Bool
        let hasLocalImmediateTask: Bool
        let hasRemoteImmediateTask: Bool
    }

    private let settings: SettingsStore
    private let localScan: LocalScan
    private let remoteHostDiscovery: RemoteHostDiscovery
    private let remoteFetch: RemoteFetch
    private let remoteFetcher: RemoteSessionFetcher
    private let periodicSleep: PeriodicSleep
    @ObservationIgnored private var localPeriodicTask: Task<Void, Never>?
    @ObservationIgnored private var remotePeriodicTask: Task<Void, Never>?
    @ObservationIgnored private var localImmediateTask: Task<Void, Never>?
    @ObservationIgnored private var remoteImmediateTask: Task<Void, Never>?
    @ObservationIgnored private var localRefreshGate = AgentSessionRefreshGate()
    @ObservationIgnored private var remoteRefreshGate = AgentSessionRemoteRefreshGate()
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var isStarted = false
    private(set) var localSessions: [AgentSession] = []
    private(set) var remoteHosts: [RemoteSessionHostResult] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var latestLocalActivityAt: Date?

    init(
        settings: SettingsStore,
        localScanner: LocalAgentSessionScanner = LocalAgentSessionScanner(),
        remoteFetcher: RemoteSessionFetcher = RemoteSessionFetcher())
    {
        self.settings = settings
        self.localScan = { includeFileOnlySessions in
            await localScanner.scan(includeFileOnlySessions: includeFileOnlySessions)
        }
        self.remoteHostDiscovery = {
            await remoteFetcher.discoveredHosts()
        }
        self.remoteFetch = { hosts in
            await remoteFetcher.fetch(hosts: hosts)
        }
        self.remoteFetcher = remoteFetcher
        self.periodicSleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        settings: SettingsStore,
        localScan: @escaping LocalScan,
        remoteFetcher: RemoteSessionFetcher = RemoteSessionFetcher())
    {
        self.settings = settings
        self.localScan = localScan
        self.remoteHostDiscovery = {
            await remoteFetcher.discoveredHosts()
        }
        self.remoteFetch = { hosts in
            await remoteFetcher.fetch(hosts: hosts)
        }
        self.remoteFetcher = remoteFetcher
        self.periodicSleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        settings: SettingsStore,
        localScan: @escaping LocalScan,
        remoteHostDiscovery: @escaping RemoteHostDiscovery,
        remoteFetch: @escaping RemoteFetch,
        periodicSleep: @escaping PeriodicSleep = { duration in try await Task.sleep(for: duration) })
    {
        self.settings = settings
        self.localScan = localScan
        self.remoteHostDiscovery = remoteHostDiscovery
        self.remoteFetch = remoteFetch
        self.remoteFetcher = RemoteSessionFetcher()
        self.periodicSleep = periodicSleep
    }

    deinit {
        self.localPeriodicTask?.cancel()
        self.remotePeriodicTask?.cancel()
        self.localImmediateTask?.cancel()
        self.remoteImmediateTask?.cancel()
    }

    var totalCount: Int {
        self.localSessions.count + self.remoteHosts.reduce(0) { $0 + $1.sessions.count }
    }

    /// Adaptive refresh uses local metadata only after explicit consent. Remote sessions remain
    /// behind the Agent Sessions setting because they can involve Tailscale discovery and SSH.
    var localMonitoringEnabled: Bool {
        self.settings.agentSessionsEnabled || self.settings.adaptiveActivityScanningEnabled
    }

    var schedulerState: SchedulerState {
        SchedulerState(
            isStarted: self.isStarted,
            hasLocalPeriodicTask: self.localPeriodicTask != nil,
            hasRemotePeriodicTask: self.remotePeriodicTask != nil,
            hasLocalImmediateTask: self.localImmediateTask != nil,
            hasRemoteImmediateTask: self.remoteImmediateTask != nil)
    }

    nonisolated static func latestActivityAt(in sessions: [AgentSession]) -> Date? {
        sessions.compactMap(\.lastActivityAt).max()
    }

    nonisolated static func shouldScanLocally(
        agentSessionsEnabled: Bool,
        adaptiveActivityScanningEnabled: Bool,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> Bool
    {
        if agentSessionsEnabled {
            return true
        }
        guard adaptiveActivityScanningEnabled, !lowPowerModeEnabled else { return false }
        return thermalState != .serious && thermalState != .critical
    }

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        self.localRefreshGate.settingsDidChange()
        self.remoteRefreshGate.settingsDidChange()
        self.reconcilePeriodicTasks()
        self.requestLocalRefresh()
        self.requestRemoteRefresh()
    }

    func stop() {
        guard self.isStarted || self.hasOwnedTasks else { return }
        self.isStarted = false
        self.localRefreshGate.settingsDidChange()
        self.remoteRefreshGate.settingsDidChange()
        self.cancelOwnedTasks()
    }

    func settingsDidChange(remoteConfigurationChanged: Bool = true) {
        self.localRefreshGate.settingsDidChange()
        if remoteConfigurationChanged {
            self.remoteRefreshGate.settingsDidChange()
        }

        let hadVisibleSessions = !self.localSessions.isEmpty || !self.remoteHosts.isEmpty
        let hadActivity = self.latestLocalActivityAt != nil
        if !self.settings.agentSessionsEnabled {
            // Adaptive keeps only the timestamp signal. Retained session paths and identities
            // remain scoped to the explicitly enabled Agent Sessions UI.
            self.localSessions = []
            self.remoteHosts = []
        }
        if !self.localMonitoringEnabled {
            self.latestLocalActivityAt = nil
        }

        self.reconcilePeriodicTasks()
        guard self.isStarted else { return }
        if hadVisibleSessions || (hadActivity && !self.localMonitoringEnabled) {
            self.onUpdate?()
        }
        self.requestLocalRefresh()
        if remoteConfigurationChanged {
            self.requestRemoteRefresh()
        }
    }

    func refreshOnMenuOpen() {
        guard self.isStarted else { return }
        self.requestLocalRefresh()
        self.requestRemoteRefresh()
    }

    func focus(_ session: AgentSession, remoteHost: String?) {
        if let remoteHost {
            Task {
                await self.remoteFetcher.focus(sessionID: session.id, host: remoteHost)
            }
        } else {
            _ = SessionWindowFocuser.focus(session)
        }
    }

    func refreshLocal() async {
        self.requestLocalRefresh()
        let task = self.localImmediateTask
        await task?.value
    }

    func applyLocalScanResult(_ sessions: [AgentSession], updatedAt: Date = Date()) {
        let latestActivityAt = Self.latestActivityAt(in: sessions)
        let effectiveSessions = self.settings.agentSessionsEnabled ? sessions : []
        // Rescans that reproduce the current content must not publish: `onUpdate` invalidates
        // menus, and a redundant invalidation landing while the user hovers an Overview row's
        // chart submenu fed the open/close rebuild flicker loop in #2652.
        if latestActivityAt == self.latestLocalActivityAt, effectiveSessions == self.localSessions {
            self.lastUpdatedAt = updatedAt
            return
        }
        self.latestLocalActivityAt = latestActivityAt
        self.localSessions = effectiveSessions
        self.lastUpdatedAt = updatedAt
        self.onUpdate?()
    }

    private var hasOwnedTasks: Bool {
        self.localPeriodicTask != nil || self.remotePeriodicTask != nil ||
            self.localImmediateTask != nil || self.remoteImmediateTask != nil
    }

    private func reconcilePeriodicTasks() {
        let needsLocalScheduler = self.isStarted && self.localMonitoringEnabled
        if needsLocalScheduler, self.localPeriodicTask == nil {
            let periodicSleep = self.periodicSleep
            self.localPeriodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await periodicSleep(.seconds(30))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.requestLocalRefresh()
                }
            }
        } else if !needsLocalScheduler {
            self.localPeriodicTask?.cancel()
            self.localPeriodicTask = nil
            self.localImmediateTask?.cancel()
        }

        let needsRemoteScheduler = self.isStarted && self.settings.agentSessionsEnabled
        if needsRemoteScheduler, self.remotePeriodicTask == nil {
            let periodicSleep = self.periodicSleep
            self.remotePeriodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await periodicSleep(.seconds(60))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.requestRemoteRefresh()
                }
            }
        } else if !needsRemoteScheduler {
            self.remotePeriodicTask?.cancel()
            self.remotePeriodicTask = nil
            self.remoteImmediateTask?.cancel()
        }
    }

    private func cancelOwnedTasks() {
        self.localPeriodicTask?.cancel()
        self.remotePeriodicTask?.cancel()
        self.localImmediateTask?.cancel()
        self.remoteImmediateTask?.cancel()
        self.localPeriodicTask = nil
        self.remotePeriodicTask = nil
        self.localImmediateTask = nil
        self.remoteImmediateTask = nil
    }

    private func requestLocalRefresh() {
        guard self.isStarted, self.localMonitoringEnabled, self.localImmediateTask == nil else { return }
        let processInfo = ProcessInfo.processInfo
        guard Self.shouldScanLocally(
            agentSessionsEnabled: self.settings.agentSessionsEnabled,
            adaptiveActivityScanningEnabled: self.settings.adaptiveActivityScanningEnabled,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState)
        else { return }
        guard let generation = self.localRefreshGate.begin() else { return }

        let includeFileOnlySessions = self.settings.agentSessionsEnabled
        let localScan = self.localScan
        self.localImmediateTask = Task { [weak self] in
            guard !Task.isCancelled else {
                self?.completeLocalRefresh(generation: generation, sessions: nil, wasCancelled: true)
                return
            }
            let sessions = await localScan(includeFileOnlySessions)
            self?.completeLocalRefresh(
                generation: generation,
                sessions: sessions,
                wasCancelled: Task.isCancelled)
        }
    }

    private func completeLocalRefresh(
        generation: Int,
        sessions: [AgentSession]?,
        wasCancelled: Bool)
    {
        self.localImmediateTask = nil
        let outcome = self.localRefreshGate.finish(generation: generation)
        if !wasCancelled, outcome.shouldPublish, self.isStarted, self.localMonitoringEnabled, let sessions {
            self.applyLocalScanResult(sessions)
        }
        if outcome.shouldRetry, self.isStarted, self.localMonitoringEnabled {
            self.requestLocalRefresh()
        }
    }

    private func requestRemoteRefresh() {
        guard self.isStarted, self.settings.agentSessionsEnabled, self.remoteImmediateTask == nil else { return }
        guard let generation = self.remoteRefreshGate.begin() else { return }

        let manualHosts = self.manualHosts
        let remoteHostDiscovery = self.remoteHostDiscovery
        let remoteFetch = self.remoteFetch
        self.remoteImmediateTask = Task { [weak self] in
            guard !Task.isCancelled else {
                self?.completeRemoteRefresh(generation: generation, results: nil, wasCancelled: true)
                return
            }
            var hosts = manualHosts
            await hosts.append(contentsOf: remoteHostDiscovery())
            let results = await remoteFetch(hosts)
            self?.completeRemoteRefresh(
                generation: generation,
                results: results,
                wasCancelled: Task.isCancelled)
        }
    }

    private func completeRemoteRefresh(
        generation: Int,
        results: [RemoteSessionHostResult]?,
        wasCancelled: Bool)
    {
        self.remoteImmediateTask = nil
        let outcome = self.remoteRefreshGate.finish(generation: generation)
        if !wasCancelled,
           outcome.shouldPublish,
           self.isStarted,
           self.settings.agentSessionsEnabled,
           let results,
           results != self.remoteHosts
        {
            self.remoteHosts = results
            self.lastUpdatedAt = Date()
            self.onUpdate?()
        }
        if outcome.shouldRetry, self.isStarted, self.settings.agentSessionsEnabled {
            self.requestRemoteRefresh()
        }
    }

    private var manualHosts: [String] {
        self.settings.agentSessionsManualHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
