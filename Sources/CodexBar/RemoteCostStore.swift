import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class RemoteCostStore {
    typealias Loader = @Sendable (String, [UsageProvider], Int, Bool) async throws -> [RemoteCostSummary]

    private(set) var reports: [RemoteHostCostReport] = []
    private(set) var isRefreshing = false
    private(set) var configurationError: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hosts: [String] = []
    @ObservationIgnored private var providers: [UsageProvider] = []
    @ObservationIgnored private var historyDays = 30
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private let loader: Loader

    init(loader: @escaping Loader = { host, providers, days, force in
        try await RemoteCostFetcher().fetch(
            host: host,
            providers: providers,
            historyDays: days,
            force: force)
    }) {
        self.loader = loader
    }

    convenience init(environment: [String: String]) {
        self.init { host, providers, days, force in
            try await RemoteCostFetcher().fetch(
                host: host,
                providers: providers,
                historyDays: days,
                force: force,
                environment: environment)
        }
    }

    deinit {
        self.task?.cancel()
    }

    func refresh(
        hosts text: String,
        providers requestedProviders: [UsageProvider],
        historyDays: Int,
        force: Bool = false,
        now: Date = Date())
    {
        let hosts: [String]
        let providers: [UsageProvider]
        do {
            hosts = try RemoteCostFetcher.hosts(from: text)
            providers = hosts.isEmpty ? [] : try RemoteCostFetcher.validatedProviders(requestedProviders)
        } catch {
            self.cancel()
            self.configurationError = error.localizedDescription
            return
        }
        self.configurationError = nil
        if self.hosts != hosts || self.providers != providers || self.historyDays != historyDays {
            self.cancel()
            self.hosts = hosts
            self.providers = providers
            self.historyDays = historyDays
        }
        guard !hosts.isEmpty, !providers.isEmpty, self.task == nil else { return }
        guard force || self.lastRefresh.map({ now.timeIntervalSince($0) >= 15 * 60 }) != false else { return }
        self.lastRefresh = now
        self.isRefreshing = true
        if self.reports.isEmpty {
            self.reports = hosts.flatMap { host in
                providers.map { RemoteHostCostReport(host: host, provider: $0, summary: nil) }
            }
        }
        let generation = self.generation
        let loader = self.loader
        self.task = Task { [weak self] in
            let fetched = await withTaskGroup(of: [RemoteHostCostReport].self) { group in
                for host in hosts {
                    group.addTask {
                        do {
                            let summaries = try await loader(host, providers, historyDays, force)
                            let summariesByProvider = Dictionary(uniqueKeysWithValues: summaries.map {
                                ($0.provider, $0)
                            })
                            return providers.map { provider in
                                RemoteHostCostReport(
                                    host: host,
                                    provider: provider,
                                    summary: summariesByProvider[provider.rawValue],
                                    error: summariesByProvider[provider.rawValue] == nil
                                        ? RemoteCostError.unavailable.localizedDescription
                                        : nil)
                            }
                        } catch {
                            return providers.map {
                                RemoteHostCostReport(
                                    host: host,
                                    provider: $0,
                                    summary: nil,
                                    error: error.localizedDescription)
                            }
                        }
                    }
                }
                var reports: [RemoteHostCostReport] = []
                for await hostReports in group {
                    reports.append(contentsOf: hostReports)
                }
                return reports
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.reports = hosts.flatMap { host in
                providers.compactMap { provider in
                    fetched.first { $0.host == host && $0.provider == provider.rawValue }
                }
            }
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
        self.providers = []
        self.lastRefresh = nil
    }
}

extension UsageStore {
    func refreshRemoteCosts(force: Bool = false) {
        let providers = RemoteCostFetcher.supportedProviders.filter { self.isEnabled($0) }
        let enabled = self.settings.costUsageEnabled && self.settings.remoteCostsEnabled && !providers.isEmpty
        self.remoteCosts.refresh(
            hosts: enabled ? self.settings.remoteCostHosts : "",
            providers: providers,
            historyDays: self.settings.costUsageHistoryDays,
            force: force)
    }
}
