import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class RemoteCodexCostStore {
    typealias Loader = @Sendable (String, Int, Bool) async throws -> CodexCostSummary

    private(set) var reports: [CodexHostCostReport] = []
    private(set) var isRefreshing = false
    private(set) var configurationError: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hosts: [String] = []
    @ObservationIgnored private var historyDays = 30
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private let loader: Loader

    init(loader: @escaping Loader = { host, days, force in
        try await RemoteCodexCostFetcher().fetch(host: host, historyDays: days, force: force)
    }) {
        self.loader = loader
    }

    convenience init(environment: [String: String]) {
        self.init { host, days, force in
            try await RemoteCodexCostFetcher().fetch(
                host: host, historyDays: days, force: force, environment: environment)
        }
    }

    deinit {
        self.task?.cancel()
    }

    func refresh(hosts text: String, historyDays: Int, force: Bool = false, now: Date = Date()) {
        let hosts: [String]
        do {
            hosts = try RemoteCodexCostFetcher.hosts(from: text)
        } catch {
            self.cancel()
            self.configurationError = error.localizedDescription
            return
        }
        self.configurationError = nil
        if self.hosts != hosts || self.historyDays != historyDays {
            self.cancel()
            self.hosts = hosts
            self.historyDays = historyDays
        }
        guard !hosts.isEmpty, self.task == nil else { return }
        guard force || self.lastRefresh.map({ now.timeIntervalSince($0) >= 15 * 60 }) != false else { return }
        self.lastRefresh = now
        self.isRefreshing = true
        if self.reports.isEmpty {
            self.reports = hosts.map { CodexHostCostReport(host: $0, summary: nil) }
        }
        let generation = self.generation
        let loader = self.loader
        self.task = Task { [weak self] in
            let reports = await withTaskGroup(of: CodexHostCostReport.self) { group in
                for host in hosts {
                    group.addTask {
                        do {
                            let summary = try await loader(host, historyDays, force)
                            return CodexHostCostReport(host: host, summary: summary)
                        } catch {
                            return CodexHostCostReport(host: host, summary: nil, error: error.localizedDescription)
                        }
                    }
                }
                var reports: [CodexHostCostReport] = []
                for await report in group {
                    reports.append(report)
                }
                return hosts.compactMap { host in reports.first { $0.host == host } }
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.reports = reports
            self.isRefreshing = false
            self.task = nil
        }
    }

    func cancel() {
        self.generation += 1
        self.task?.cancel()
        self.task = nil
        self.isRefreshing = false
        self.reports = []
        self.hosts = []
        self.lastRefresh = nil
    }
}

extension UsageStore {
    func refreshRemoteCodexCosts(force: Bool = false) {
        // Provider-specific by design: only Codex has a supported remote cost-summary protocol.
        let enabled = self.settings.costUsageEnabled && self.isEnabled(.codex)
        self.remoteCodexCosts.refresh(
            hosts: enabled ? self.settings.codexRemoteCostHosts : "",
            historyDays: self.settings.costUsageHistoryDays,
            force: force)
    }
}
