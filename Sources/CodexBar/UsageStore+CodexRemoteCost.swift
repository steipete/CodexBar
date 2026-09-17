import CodexBarCore
import Foundation
import Observation

extension UsageStore {
    var codexRemoteCostObservationToken: Int {
        _ = self.codexRemoteCosts.result
        _ = self.codexRemoteCosts.enabled
        _ = self.codexRemoteCosts.host
        _ = self.codexRemoteCosts.home
        _ = self.codexRemoteCosts.errorMessage
        _ = self.codexRemoteCosts.phase
        _ = self.codexRemoteCosts.isCheckingConfiguration
        _ = self.codexRemoteContextCache.value
        _ = self.codexRemoteContextCache.revision
        return 0
    }

    /// Remote costs only use ambient history; identifying an unsupported scope must not load its account files.
    var codexRemoteLocalScope: String {
        if self.settings.codexLocalSessionCostLedgerEnabled { return "codex:ambient" }
        switch self.settings.codexActiveSource {
        case .liveSystem: return "codex:ambient"
        case let .managedAccount(id): return "codex:managed:\(id.uuidString)"
        case let .profileHome(path): return "codex:profile:\(path)"
        }
    }

    func remoteCostPresentationEnabled(for provider: UsageProvider) -> Bool {
        provider == .codex && self.codexRemoteCosts.enabled &&
            self.codexRemoteLocalScope == "codex:ambient"
    }

    func costPresentationShowsInline(for provider: UsageProvider) -> Bool {
        self.settings.costSummaryShowsInline(for: provider) ||
            (self.remoteCostPresentationEnabled(for: provider) && self.settings.costSummaryDisplayStyle
                .showsInlineSummary)
    }

    func costPresentationShowsSubmenu(for provider: UsageProvider) -> Bool {
        self.settings.costSummaryShowsSubmenu(for: provider) ||
            (self.remoteCostPresentationEnabled(for: provider) && self.settings.costSummaryDisplayStyle
                .showsCostSubmenu)
    }

    func codexRemoteCostContextInput(now: Date = Date()) -> CodexRemoteCostContextInput {
        CodexRemoteCostContextInput(
            source: self.codexRemoteCosts.source,
            localCodexHome: CodexHomeScope.ambientHomeURL(env: self.environmentBase),
            localScope: self.codexRemoteLocalScope,
            historyDays: self.settings.costUsageHistoryDays,
            calendar: self.settings.costUsageBucketCalendar,
            pricingCacheRoot: self.codexRemotePricingCacheRoot,
            localCostCacheRoot: self.codexRemoteLocalCostCacheRoot,
            sshEnvironment: self.environmentBase.filter { $0.key == "HOME" || $0.key == "CODEXBAR_SSH_CONFIG_FILE" },
            now: now)
    }

    @discardableResult
    func prepareCodexRemoteCostContext(now: Date = Date()) -> CodexRemoteCostContextInput {
        let input = self.codexRemoteCostContextInput(now: now)
        if self.codexRemoteContextCache.select(input) { self.codexRemoteCosts.invalidate() }
        return input
    }

    func codexRemoteCostContext(now: Date = Date()) async throws -> CodexRemoteCostContext {
        let input = self.prepareCodexRemoteCostContext(now: now)
        return try await self.codexRemoteContextCache.fresh(for: input)
    }

    /// Only the ambient menu/settings cost presentation consults this selector. Publication and spend stay local.
    func codexCostPresentationSnapshot(now: Date = Date()) -> CostUsageTokenSnapshot? {
        guard self.codexRemoteCosts.enabled else { return self.tokenSnapshot(for: .codex) }
        let input = self.prepareCodexRemoteCostContext(now: now)
        guard let context = self.codexRemoteContextCache.cached(for: input) else {
            return self.tokenSnapshot(for: .codex)
        }
        return self.codexRemoteCosts.selectedResult(context: context)?.snapshot ?? self.tokenSnapshot(for: .codex)
    }

    func codexRemoteCostPresentation(now: Date = Date()) -> CodexRemoteCostPresentation? {
        guard self.codexRemoteCosts.enabled else { return nil }
        let input = self.prepareCodexRemoteCostContext(now: now)
        guard input.localScope == "codex:ambient" else { return nil }
        let context = self.codexRemoteContextCache.cached(for: input)
        let state = self.codexRemoteCosts
        let result = context.flatMap { state.selectedResult(context: $0) }
        let host = self.settings.hidePersonalInfo ? "Server" : input.source.host
        let title = result == nil ? "Only this Mac" : "Native Codex · This Mac + \(host)"
        var details = [
            result == nil ? "This Mac’s local cost history" : "Native Codex logs",
            "Day boundary: \(input.calendar.timeZone.identifier)",
        ]
        if let result {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            formatter.timeZone = input.calendar.timeZone
            details.append("As of \(formatter.string(from: result.capturedTo))")
        }
        var status: String
        if let error = state.errorMessage {
            status = error
        } else if state.isCheckingConfiguration || (context == nil && !state.isRunning) {
            status = "Checking source configuration…"
        } else if state.isRunning {
            switch state.phase {
            case .fetching: status = "Fetching server logs…"
            case .scanning: status = "Scanning native logs…"
            case .cleaning: status = "Removing temporary logs…"
            case nil: status = "Cancelling and removing temporary logs…"
            }
        } else if let result {
            let snapshot = result.snapshot
            let hasUnpriced = snapshot.daily.contains { ($0.unpricedRequestCount ?? 0) > 0 || $0.costUSD == nil }
            let quality = snapshot.historyCoverageIsEstablished && snapshot.last30DaysCostUSD != nil && !hasUnpriced
                ? "" : "Partial known values; missing prices or history are not zero. "
            status = quality + result.notices.joined(separator: " ")
        } else {
            status = state.needsRefresh ? "Server statistics need a manual refresh." : "Server has not been read."
        }
        if result == nil, self.tokenSnapshot(for: .codex) == nil {
            status += " This Mac’s local history is unavailable; no zero amount is assumed."
        }
        return CodexRemoteCostPresentation(
            title: title,
            detail: details.joined(separator: " · "),
            status: status,
            isCombined: result != nil)
    }

    func refreshCodexRemoteCosts() {
        let input = self.prepareCodexRemoteCostContext()
        guard input.localScope == "codex:ambient" else { return }
        self.codexRemoteCosts.refresh(
            contextProvider: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.codexRemoteContextCache.fresh(for: input)
            },
            currentContext: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.codexRemoteCostContext()
            })
    }

    func observeCodexRemoteCostContext() {
        withObservationTracking {
            _ = self.settings.costUsageHistoryDays
            _ = self.settings.costUsageBucketTimeZoneIdentifier
            _ = self.settings.codexLocalSessionCostLedgerEnabled
            _ = self.settings.codexActiveSource
            _ = self.codexRemoteCosts.enabled
            _ = self.codexRemoteCosts.host
            _ = self.codexRemoteCosts.home
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.codexRemoteCosts.enabled {
                    let input = self.prepareCodexRemoteCostContext()
                    _ = self.codexRemoteContextCache.cached(for: input)
                } else {
                    self.codexRemoteContextCache.invalidate()
                }
                self.observeCodexRemoteCostContext()
            }
        }
    }
}
