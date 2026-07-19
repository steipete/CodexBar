import CodexBarCore
import Foundation
import Observation

struct AgentSessionRemoteRefreshGate {
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

@MainActor
@Observable
final class AgentSessionsStore {
    typealias LocalScan = @Sendable (_ includeFileOnlySessions: Bool) async -> [AgentSession]

    private let settings: SettingsStore
    private let localScan: LocalScan
    private let remoteFetcher: RemoteSessionFetcher
    @ObservationIgnored private var localRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var localRefreshInFlight = false
    @ObservationIgnored private var remoteRefreshGate = AgentSessionRemoteRefreshGate()
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

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
        self.remoteFetcher = remoteFetcher
    }

    init(
        settings: SettingsStore,
        localScan: @escaping LocalScan,
        remoteFetcher: RemoteSessionFetcher = RemoteSessionFetcher())
    {
        self.settings = settings
        self.localScan = localScan
        self.remoteFetcher = remoteFetcher
    }

    var totalCount: Int {
        self.localSessions.count + self.remoteHosts.reduce(0) { $0 + $1.sessions.count }
    }

    /// Adaptive refresh uses local metadata only after explicit consent. Remote sessions remain
    /// behind the Agent Sessions setting because they can involve Tailscale discovery and SSH.
    var localMonitoringEnabled: Bool {
        self.settings.agentSessionsEnabled || self.settings.adaptiveActivityScanningEnabled
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
        guard self.localRefreshTask == nil, self.remoteRefreshTask == nil else { return }
        self.localRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLocal()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        self.remoteRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRemote()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        self.localRefreshTask?.cancel()
        self.remoteRefreshTask?.cancel()
        self.localRefreshTask = nil
        self.remoteRefreshTask = nil
    }

    func settingsDidChange(remoteConfigurationChanged: Bool = true) {
        if remoteConfigurationChanged {
            self.remoteRefreshGate.settingsDidChange()
        }
        if !self.settings.agentSessionsEnabled {
            // Adaptive keeps only the timestamp signal. Retained session paths and identities
            // remain scoped to the explicitly enabled Agent Sessions UI.
            self.localSessions = []
            self.remoteHosts = []
        }
        guard self.localMonitoringEnabled else {
            self.latestLocalActivityAt = nil
            self.onUpdate?()
            return
        }
        guard !SettingsStore.isRunningTests else { return }
        Task { [weak self] in
            await self?.refreshLocal()
            if remoteConfigurationChanged, self?.settings.agentSessionsEnabled == true {
                await self?.refreshRemote()
            }
        }
    }

    func refreshOnMenuOpen() {
        guard self.localMonitoringEnabled, !SettingsStore.isRunningTests else { return }
        Task { [weak self] in
            await self?.refreshLocal()
            if self?.settings.agentSessionsEnabled == true {
                await self?.refreshRemote()
            }
        }
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
        guard self.localMonitoringEnabled, !self.localRefreshInFlight else { return }
        let processInfo = ProcessInfo.processInfo
        guard Self.shouldScanLocally(
            agentSessionsEnabled: self.settings.agentSessionsEnabled,
            adaptiveActivityScanningEnabled: self.settings.adaptiveActivityScanningEnabled,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState)
        else { return }
        self.localRefreshInFlight = true
        let sessions = await self.localScan(self.settings.agentSessionsEnabled)
        self.localRefreshInFlight = false
        guard !Task.isCancelled, self.localMonitoringEnabled else { return }
        self.applyLocalScanResult(sessions)
    }

    func applyLocalScanResult(_ sessions: [AgentSession], updatedAt: Date = Date()) {
        self.latestLocalActivityAt = Self.latestActivityAt(in: sessions)
        self.localSessions = self.settings.agentSessionsEnabled ? sessions : []
        self.lastUpdatedAt = updatedAt
        self.onUpdate?()
    }

    private func refreshRemote() async {
        guard self.settings.agentSessionsEnabled else { return }
        guard var generation = self.remoteRefreshGate.begin() else { return }
        while self.settings.agentSessionsEnabled {
            var hosts = self.manualHosts
            await hosts.append(contentsOf: self.remoteFetcher.discoveredHosts())
            let results = await self.remoteFetcher.fetch(hosts: hosts)
            let outcome = self.remoteRefreshGate.finish(generation: generation)
            guard !Task.isCancelled, self.settings.agentSessionsEnabled else { return }
            if outcome.shouldPublish {
                self.remoteHosts = results
                self.lastUpdatedAt = Date()
                self.onUpdate?()
            }
            guard outcome.shouldRetry, let nextGeneration = self.remoteRefreshGate.begin() else { return }
            generation = nextGeneration
        }
    }

    private var manualHosts: [String] {
        self.settings.agentSessionsManualHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
