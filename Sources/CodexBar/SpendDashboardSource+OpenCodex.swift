import CodexBarCore
import Foundation

extension SpendDashboardSource {
    static func mergingOpenCodexInputs(
        _ inputs: [SpendDashboardModel.ProviderInput],
        request: SpendDashboardLoadRequest) -> [SpendDashboardModel.ProviderInput]
    {
        self.mergingOpenCodexInputsWithObservation(inputs, request: request).inputs
    }

    static func mergingOpenCodexInputsWithObservation(
        _ inputs: [SpendDashboardModel.ProviderInput],
        request: SpendDashboardLoadRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        entryLoader: ((URL, Date?) throws -> [OpenCodexUsageEntry])? = nil) -> (
        inputs: [SpendDashboardModel.ProviderInput],
        observation: SpendDashboardLoadResult.OpenCodexObservation)
    {
        guard request.configuration.openCodexUsageLogsEnabled,
              !request.configuration.hiddenSourceIDs.contains(SpendDashboardModel.openCodexSourceID)
        else {
            return (
                inputs.filter { $0.id != SpendDashboardModel.openCodexSourceID },
                .disabled)
        }
        guard let logURL = OpenCodexUsageLog.usageLogURL(environment: environment) else {
            return (inputs.filter { $0.id != SpendDashboardModel.openCodexSourceID }, .unavailable)
        }
        let store = OpenCodexUsageStore(cacheRoot: OpenCodexUsageLog.cacheRoot())
        let entries: [OpenCodexUsageEntry]
        do {
            let since = OpenCodexUsageStore.windowStart(
                now: request.now,
                historyDays: Self.scanDays,
                calendar: request.configuration.bucketCalendar)
            entries = try entryLoader?(logURL, since) ?? store.loadEntries(logURL: logURL, since: since)
        } catch {
            return (inputs.filter { $0.id != SpendDashboardModel.openCodexSourceID }, .unavailable)
        }
        guard !entries.isEmpty else {
            return (inputs.filter { $0.id != SpendDashboardModel.openCodexSourceID }, .confirmedEmpty)
        }

        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries,
            now: request.now,
            historyDays: Self.scanDays,
            calendar: request.configuration.bucketCalendar)
        var merged = inputs.filter { $0.id != SpendDashboardModel.openCodexSourceID }
        var published = false

        for (provider, supplement) in snapshots {
            guard Self.shouldPublishOpenCodexSnapshot(supplement) else { continue }
            published = true
            // Provider-specific by design: hide-native keeps OpenCodex on its own Codex row
            // so visibleInputs can drop overlapping native Codex snapshots.
            if provider == .codex,
               request.configuration.hideNativeCodexCostWhenOpenCodexPresent
            {
                merged.append(SpendDashboardModel.ProviderInput(
                    id: SpendDashboardModel.openCodexSourceID,
                    provider: provider,
                    displayName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
                    snapshot: supplement,
                    sourceKind: .openCodex))
                continue
            }
            if let index = Self.preferredMergeIndex(for: provider, in: merged) {
                merged[index] = Self.mergeProviderInput(
                    merged[index],
                    supplement: supplement,
                    request: request)
            } else {
                merged.append(SpendDashboardModel.ProviderInput(
                    provider: provider,
                    displayName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
                    snapshot: supplement,
                    sourceKind: .openCodex))
            }
        }
        return (merged, published ? .available : .confirmedEmpty)
    }

    static func preferredMergeIndex(
        for provider: UsageProvider,
        in inputs: [SpendDashboardModel.ProviderInput]) -> Int?
    {
        // Provider-specific by design: OpenCodex fan-out merges into the native Codex subscription row when exactly one
        // exists.
        if provider == .codex {
            let codexIndices = inputs.indices.filter { inputs[$0].provider == .codex }
            guard codexIndices.count == 1 else { return nil }
            return codexIndices.first
        }
        let matching = inputs.indices.filter { inputs[$0].provider == provider }
        guard matching.count == 1 else {
            return inputs.firstIndex(where: { $0.provider == provider && $0.sourceKind == .native })
        }
        return matching.first
    }

    private static func mergeProviderInput(
        _ input: SpendDashboardModel.ProviderInput,
        supplement: CostUsageTokenSnapshot,
        request: SpendDashboardLoadRequest) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: input.id,
            provider: input.provider,
            displayName: input.displayName,
            modelProviderName: input.modelProviderName,
            snapshot: OpenCodexUsageFanOut.mergeSnapshots(
                input.snapshot,
                supplement,
                now: request.now,
                historyDays: self.scanDays,
                calendar: request.configuration.bucketCalendar),
            tokenActivityCache: input.tokenActivityCache,
            sourceKind: input.sourceKind)
    }

    static func shouldPublishOpenCodexSnapshot(_ snapshot: CostUsageTokenSnapshot) -> Bool {
        !snapshot.daily.isEmpty || !snapshot.sessions.isEmpty
    }
}
