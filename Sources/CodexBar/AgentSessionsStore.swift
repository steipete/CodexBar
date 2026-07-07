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
            self.isPending = true
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
    private let settings: SettingsStore
    private let localScanner: LocalAgentSessionScanner
    private let remoteFetcher: RemoteSessionFetcher
    @ObservationIgnored private var localRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var remoteRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var localRefreshInFlight = false
    @ObservationIgnored private var remoteRefreshGate = AgentSessionRemoteRefreshGate()
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    private(set) var localSessions: [AgentSession] = []
    private(set) var remoteHosts: [RemoteSessionHostResult] = []
    private(set) var lastUpdatedAt: Date?

    init(
        settings: SettingsStore,
        localScanner: LocalAgentSessionScanner = LocalAgentSessionScanner(),
        remoteFetcher: RemoteSessionFetcher = RemoteSessionFetcher())
    {
        self.settings = settings
        self.localScanner = localScanner
        self.remoteFetcher = remoteFetcher
    }

    var totalCount: Int {
        self.localSessions.count + self.remoteHosts.reduce(0) { $0 + $1.sessions.count }
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

    func settingsDidChange() {
        self.remoteRefreshGate.settingsDidChange()
        guard self.settings.agentSessionsEnabled else {
            self.localSessions = []
            self.remoteHosts = []
            self.onUpdate?()
            return
        }
        guard !SettingsStore.isRunningTests else { return }
        Task { [weak self] in
            await self?.refreshLocal()
            await self?.refreshRemote()
        }
    }

    func refreshOnMenuOpen() {
        guard self.settings.agentSessionsEnabled, !SettingsStore.isRunningTests else { return }
        Task { [weak self] in
            await self?.refreshLocal()
            await self?.refreshRemote()
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

    private func refreshLocal() async {
        guard self.settings.agentSessionsEnabled, !self.localRefreshInFlight else { return }
        self.localRefreshInFlight = true
        let sessions = await self.localScanner.scan()
        self.localRefreshInFlight = false
        guard !Task.isCancelled, self.settings.agentSessionsEnabled else { return }
        self.localSessions = sessions
        self.lastUpdatedAt = Date()
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
