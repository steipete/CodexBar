import CodexBarCore
import Foundation
import Observation

enum OpenAILiveUsagePolling {
    static func interval(after error: OpenAILiveUsageError?, previous: TimeInterval) -> TimeInterval {
        switch error {
        case .rateLimited: min(300, max(30, previous) * 2)
        case nil: 30
        default: max(30, previous)
        }
    }
}

enum OpenAILiveUsageLimitsPolicy {
    static func shouldFetch(lastAttempt: Date?, now: Date, manual: Bool) -> Bool {
        guard let lastAttempt else { return true }
        let age = now.timeIntervalSince(lastAttempt)
        return manual ? age > 5 * 60 : age >= 15 * 60
    }

    static func showsRule(limit: Int, peak: Int) -> Bool {
        limit > 0 && Double(limit) <= 1.5 * Double(peak)
    }

    /// The chart plots all traffic; only non-pending totals determine whether the rule fits its scale.
    static func showsRule(limit: Int, points: [OpenAILiveUsageSnapshot.Point]) -> Bool {
        self.showsRule(limit: limit, peak: points.filter { !$0.isPending }.map(\.totalTokens).max() ?? 0)
    }
}

@Observable
@MainActor
final class OpenAILiveUsageModel {
    typealias FetchLimits = @Sendable ([String: String]) async throws -> OpenAIOrgRateLimits
    typealias Fetch = @Sendable ([String: String], Int) async throws -> OpenAILiveUsageSnapshot

    var filter: OpenAILiveUsageModelFilter = .allModels
    var windowMinutes = 60 {
        didSet {
            guard self.windowMinutes != oldValue else { return }
            self.generation += 1
            if self.isActive { self.refresh(manual: false) }
        }
    }

    private(set) var projectCaps: OpenAIOrgRateLimits?
    private(set) var limitsError: String?
    private(set) var displayedLimitScope: ProviderModelRateLimitScope?
    @ObservationIgnored private let limitScope: @MainActor () -> ProviderModelRateLimitScope
    @ObservationIgnored private let manualLimits: @MainActor (ProviderModelRateLimitScope) -> [ProviderModelRateLimit]
    @ObservationIgnored private let fetchLimits: FetchLimits
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var limitsTask: Task<Void, Never>?
    @ObservationIgnored private var limitsRequestID = UUID()
    @ObservationIgnored private var limitsLastAttempt: Date?
    /// Outer nil: not observed yet. Inner nil: no credential resolved.
    @ObservationIgnored private var limitsScope: OpenAILiveUsageScope??
    @ObservationIgnored private var usageScope: OpenAILiveUsageScope??

    var limits: OpenAIOrgLimitResolver {
        OpenAIOrgLimitResolver(
            manual: self.manualLimits(self.displayedLimitScope ?? self.limitScope()),
            projectCaps: self.projectCaps)
    }

    private(set) var snapshot: OpenAILiveUsageSnapshot?
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var isMissingCredential = false
    private(set) var isRateLimited = false
    private(set) var lastUpdated: Date?
    private(set) var nextRefreshAt: Date?
    private(set) var pollingInterval: TimeInterval = 30
    private(set) var isActive = false
    @ObservationIgnored private let environment: @MainActor () -> [String: String]
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var generation = 0

    init(
        environment: @escaping @MainActor () -> [String: String],
        limitScope: @escaping @MainActor () -> ProviderModelRateLimitScope = { .provider },
        manualLimits: @escaping @MainActor (ProviderModelRateLimitScope) -> [ProviderModelRateLimit] = { _ in [] },
        now: @escaping @MainActor () -> Date = { Date() },
        fetchLimits: @escaping FetchLimits = { try await OpenAIOrgRateLimitsFetcher().fetch(environment: $0) },
        fetch: @escaping Fetch = { environment, minutes in
            try await OpenAILiveUsageFetcher().fetch(environment: environment, windowMinutes: minutes)
        })
    {
        self.environment = environment
        self.limitScope = limitScope
        self.manualLimits = manualLimits
        self.now = now
        self.fetchLimits = fetchLimits
        self.fetch = fetch
    }

    func start() {
        guard !self.isActive else { return }
        self.isActive = true
        self.limitsLastAttempt = nil
        self.refresh(manual: false)
    }

    func stop() {
        self.isActive = false
        self.generation += 1
        self.refreshPending = false
        self.pollingTask?.cancel()
        self.pollingTask = nil
        self.nextRefreshAt = nil
        self.fetchTask?.cancel()
        self.limitsTask?.cancel()
        self.limitsTask = nil
        self.limitsRequestID = UUID()
    }

    func refresh(manual: Bool = true) {
        guard self.isActive else { return }
        let environment = self.environment()
        let limitScope = self.limitScope()
        self.resetIfScopeChanged(environment, limitScope: limitScope)
        self.displayedLimitScope = limitScope
        self.refreshLimits(environment: environment, manual: manual)
        self.pollingTask?.cancel()
        self.pollingTask = nil
        self.nextRefreshAt = nil
        guard self.fetchTask == nil else {
            self.refreshPending = true
            return
        }
        self.refreshPending = false
        self.isLoading = true
        let minutes = self.windowMinutes
        let generation = self.generation
        let fetch = self.fetch
        self.fetchTask = Task { [weak self] in
            do {
                let snapshot = try await fetch(environment, minutes)
                guard let self else { return }
                if self.isActive, self.generation == generation, !Task.isCancelled {
                    self.snapshot = snapshot
                    self.lastUpdated = snapshot.fetchedAt
                    self.lastError = nil
                    self.isMissingCredential = false
                    self.isRateLimited = false
                    self.pollingInterval = OpenAILiveUsagePolling.interval(after: nil, previous: self.pollingInterval)
                }
            } catch {
                guard let self else { return }
                if self.isActive, self.generation == generation, !Task.isCancelled {
                    let typed = error as? OpenAILiveUsageError
                    self.lastError = OpenAILiveUsageErrorText.message(error)
                    self.isMissingCredential = typed == .missingCredential
                    self.isRateLimited = typed == .rateLimited
                    self.pollingInterval = OpenAILiveUsagePolling.interval(
                        after: typed ?? .apiFailure(0), previous: self.pollingInterval)
                }
            }
            guard let self else { return }
            self.fetchTask = nil
            self.isLoading = false
            guard self.isActive else { return }
            if self.refreshPending || self.generation != generation {
                self.refresh(manual: false)
            } else {
                self.scheduleNextRefresh()
            }
        }
    }

    /// A different account, key, or project is a different data scope: drop the previous organization's usage and
    /// model filter, and invalidate any in-flight fetch so its result cannot land in the new scope.
    private func resetIfScopeChanged(
        _ environment: [String: String],
        limitScope: ProviderModelRateLimitScope)
    {
        let scope = OpenAILiveUsageScope(environment: environment)
        defer { self.usageScope = .some(scope) }
        guard let previous = self.usageScope,
              previous != scope || self.displayedLimitScope != limitScope else { return }
        self.generation += 1
        self.snapshot = nil
        self.lastUpdated = nil
        self.lastError = nil
        self.isMissingCredential = false
        self.isRateLimited = false
        self.filter = .allModels
        self.pollingInterval = OpenAILiveUsagePolling.interval(after: nil, previous: self.pollingInterval)
    }

    func waitForRefresh() async {
        await self.fetchTask?.value
    }

    func waitForLimitsRefresh() async {
        await self.limitsTask?.value
    }

    private func refreshLimits(environment: [String: String], manual: Bool) {
        let scope = OpenAILiveUsageScope(environment: environment)
        if self.limitsScope != .some(scope) {
            self.limitsTask?.cancel()
            self.limitsTask = nil
            self.limitsRequestID = UUID()
            self.projectCaps = nil
            self.limitsError = nil
            self.limitsLastAttempt = nil
            self.limitsScope = .some(scope)
        }
        guard self.limitsTask == nil,
              OpenAILiveUsageLimitsPolicy.shouldFetch(
                  lastAttempt: self.limitsLastAttempt,
                  now: self.now(),
                  manual: manual)
        else { return }
        self.limitsLastAttempt = self.now()
        let requestID = UUID()
        self.limitsRequestID = requestID
        let fetch = self.fetchLimits
        self.limitsTask = Task { [weak self] in
            do {
                let limits = try await fetch(environment)
                guard let self, self.isActive, self.limitsRequestID == requestID, !Task.isCancelled else { return }
                self.projectCaps = limits
                self.limitsError = nil
            } catch {
                guard let self, self.isActive, self.limitsRequestID == requestID, !Task.isCancelled else { return }
                self.limitsError = OpenAILiveUsageErrorText.message(error)
            }
            guard let self, self.limitsRequestID == requestID else { return }
            self.limitsTask = nil
        }
    }

    private func scheduleNextRefresh() {
        let interval = self.pollingInterval
        self.nextRefreshAt = Date().addingTimeInterval(interval)
        self.pollingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            self?.refresh(manual: false)
        }
    }
}
