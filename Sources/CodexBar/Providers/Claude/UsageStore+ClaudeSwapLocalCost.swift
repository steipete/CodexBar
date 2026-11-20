import CodexBarCore
import Foundation

struct ClaudeSwapLocalCostRequest: Equatable {
    let directories: [String: String]
    let calendar: Calendar
    let period: CostReportingPeriod
    let historyDays: Int
    let settingsRevision: UInt64
}

struct ClaudeSwapLocalCostState {
    var request: ClaudeSwapLocalCostRequest?
    var attemptedAt: Date?
    var snapshots: [String: CostUsageTokenSnapshot] = [:]
    var task: Task<Void, Never>?
}

extension UsageStore {
    var hasClaudeSwapLocalCostProfiles: Bool {
        self.settings.claudeSwapSource == .claudeSwap &&
            self.settings.providerConfig(for: .claude)?.claudeSwapCostProfiles?.isEmpty == false
    }

    func claudeSwapLocalTokenCost(for account: ProviderAccountUsageSnapshot) -> CostUsageTokenSnapshot? {
        guard account.id.source == ClaudeSwapAccountProjection.sourceName,
              let key = account.historyAccountKey,
              let request = self.claudeSwapLocalCostRequest(now: Date()),
              self.claudeSwapLocalCostState.request == request
        else { return nil }
        return self.claudeSwapLocalCostState.snapshots[key]
    }

    func resetClaudeSwapLocalCost() {
        self.claudeSwapLocalCostState.task?.cancel()
        self.claudeSwapLocalCostState = ClaudeSwapLocalCostState()
        self.claudeSwapRevision &+= 1
    }

    func scheduleClaudeSwapLocalCostRefresh(force: Bool = false, now: Date = Date()) {
        let request = self.claudeSwapLocalCostRequest(now: now)
        if self.claudeSwapLocalCostState.request != request {
            self.claudeSwapLocalCostState.task?.cancel()
            self.claudeSwapLocalCostState = ClaudeSwapLocalCostState(request: request)
            self.claudeSwapRevision &+= 1
        }
        guard let request, self.claudeSwapLocalCostState.task == nil else { return }
        if !force, let attemptedAt = self.claudeSwapLocalCostState.attemptedAt,
           now >= attemptedAt,
           now.timeIntervalSince(attemptedAt) < (self.tokenFetchTTL ?? Self.minimumTokenFetchTTL)
        {
            return
        }
        self.claudeSwapLocalCostState.attemptedAt = now
        self.claudeSwapLocalCostState.task = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshots: [String: CostUsageTokenSnapshot] = [:]
            for (key, directory) in request.directories {
                guard !Task.isCancelled else { return }
                let result = try? await self.loadTokenUsageSnapshot(
                    provider: .claude,
                    force: force,
                    now: now,
                    codexHomePath: nil,
                    historyDays: request.historyDays,
                    includePiSessions: false,
                    claudeConfigDirectoryOverride: directory,
                    isolatesClaudeDirectoryCache: true)
                snapshots[key] = result?.snapshot.reporting(request.period)
            }
            guard !Task.isCancelled else { return }
            self.claudeSwapLocalCostState.task = nil
            guard self.claudeSwapLocalCostRequest(now: now) == request,
                  self.claudeSwapLocalCostState.snapshots != snapshots
            else { return }
            self.claudeSwapLocalCostState.snapshots = snapshots
            self.claudeSwapRevision &+= 1
        }
    }

    private func claudeSwapLocalCostRequest(now: Date) -> ClaudeSwapLocalCostRequest? {
        guard self.hasClaudeSwapLocalCostProfiles,
              self.shouldFetchClaudeSwapAccounts(),
              self.settings.isCostUsageEffectivelyEnabled(for: .claude),
              let profiles = self.settings.providerConfig(for: .claude)?.claudeSwapCostProfiles
        else { return nil }

        let accounts = Set(self.claudeSwapAccountSnapshots.filter {
            $0.id.source == ClaudeSwapAccountProjection.sourceName
        }.compactMap(\.historyAccountKey))
        let mappings = profiles.compactMap { profile -> (String, String)? in
            guard profile.configDirectory.hasPrefix("/"),
                  let key = ClaudeSwapAccountProjection.historyAccountKey(
                      email: profile.email, organizationUuid: profile.organizationUuid ?? "", source: .claudeSwap),
                  accounts.contains(key)
            else { return nil }
            return (key, profile.configDirectory)
        }
        let directories = Dictionary(grouping: mappings, by: { $0.0 }).compactMapValues { entries in
            entries.count == 1 ? entries.first?.1 : nil
        }
        guard !directories.isEmpty else { return nil }
        let calendar = self.settings.costUsageBucketCalendar
        let period = self.settings.costReportingPeriod
        return ClaudeSwapLocalCostRequest(
            directories: directories,
            calendar: calendar,
            period: period,
            historyDays: period.days(now: now, calendar: calendar),
            settingsRevision: self.settings.costUsageSettingsRevision)
    }
}
