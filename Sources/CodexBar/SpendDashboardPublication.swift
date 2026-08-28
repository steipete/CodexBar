import CodexBarCore
import Foundation

struct SpendSourcePublication: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case subscription
        case enrichment
    }

    enum State: Sendable, Equatable {
        case loading
        case available
        case confirmedEmpty
        case unavailable
        case staleLastKnown
    }

    let id: String
    let provider: UsageProvider?
    let displayName: String
    let role: Role
    let state: State
}

struct SpendDashboardPublication: Sendable {
    let revision: UInt64
    let generation: UInt64
    let configuration: SpendDashboardConfiguration?
    let loadedAt: Date
    let isRefreshing: Bool
    let inputs: [SpendDashboardModel.ProviderInput]
    let sources: [SpendSourcePublication]

    static let empty = SpendDashboardPublication(
        revision: 0,
        generation: 0,
        configuration: nil,
        loadedAt: .distantPast,
        isRefreshing: false,
        inputs: [],
        sources: [])

    func model(
        requestedDays: Int,
        now: Date,
        calendar: Calendar,
        preferredCurrencyCode: String,
        hiddenSourceIDs: Set<String> = [],
        hideNativeCodexWhenOpenCodexPresent: Bool = false,
        selectedDay: Date? = nil,
        providerScope: Set<UsageProvider>? = nil) -> SpendDashboardModel
    {
        let staleSourceIDs = Set(self.sources.compactMap { source in
            source.state == .staleLastKnown ? source.id : nil
        })
        let inputs = self.inputs.filter { input in
            (providerScope?.contains(input.provider) ?? true) && !staleSourceIDs.contains(input.id)
        }
        return SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: requestedDays,
            now: now,
            calendar: calendar,
            preferredCurrencyCode: preferredCurrencyCode,
            hiddenSourceIDs: hiddenSourceIDs,
            hideNativeCodexWhenOpenCodexPresent: hideNativeCodexWhenOpenCodexPresent,
            selectedDay: selectedDay)
    }

    func subscriptionCount(
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String> = [],
        hideNativeCodexWhenOpenCodexPresent: Bool = false) -> Int
    {
        providerScope.reduce(into: 0) { count, provider in
            let rosterSources = self.subscriptionRosterSources(for: provider)
            let coverageSources = self.coverageSources(
                for: provider,
                hiddenSourceIDs: hiddenSourceIDs,
                hideNativeCodexWhenOpenCodexPresent: hideNativeCodexWhenOpenCodexPresent)
            if rosterSources.isEmpty, coverageSources.isEmpty {
                count += hiddenSourceIDs.contains(provider.rawValue) ? 0 : 1
            } else {
                count += coverageSources.count
            }
        }
    }

    func knownCostSubscriptionCount(
        model: SpendDashboardModel,
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String> = [],
        hideNativeCodexWhenOpenCodexPresent: Bool = false) -> Int
    {
        let knownInputIDs = Set(model.groups.flatMap(\.providers).compactMap { row in
            row.totalCost == nil ? nil : row.id
        })
        return self.knownSubscriptionCount(
            knownInputIDs: knownInputIDs,
            providerScope: providerScope,
            hiddenSourceIDs: hiddenSourceIDs,
            hideNativeCodexWhenOpenCodexPresent: hideNativeCodexWhenOpenCodexPresent)
    }

    func knownTokenSubscriptionCount(
        model: SpendDashboardModel,
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String> = [],
        hideNativeCodexWhenOpenCodexPresent: Bool = false) -> Int
    {
        let knownInputIDs = Set(model.groups.flatMap(\.providers).compactMap { row in
            row.totalTokens == nil ? nil : row.id
        })
        return self.knownSubscriptionCount(
            knownInputIDs: knownInputIDs,
            providerScope: providerScope,
            hiddenSourceIDs: hiddenSourceIDs,
            hideNativeCodexWhenOpenCodexPresent: hideNativeCodexWhenOpenCodexPresent)
    }

    private func knownSubscriptionCount(
        knownInputIDs: Set<String>,
        providerScope: Set<UsageProvider>,
        hiddenSourceIDs: Set<String>,
        hideNativeCodexWhenOpenCodexPresent: Bool) -> Int
    {
        providerScope.reduce(into: 0) { count, provider in
            count += self.coverageSources(
                for: provider,
                hiddenSourceIDs: hiddenSourceIDs,
                hideNativeCodexWhenOpenCodexPresent: hideNativeCodexWhenOpenCodexPresent)
                .count { source in
                    source.state == .confirmedEmpty ||
                        (source.state == .available && knownInputIDs.contains(source.id))
                }
        }
    }

    private func subscriptionRosterSources(for provider: UsageProvider) -> [SpendSourcePublication] {
        self.sources.filter { $0.provider == provider && $0.role == .subscription }
    }

    private func coverageSources(
        for provider: UsageProvider,
        hiddenSourceIDs: Set<String>,
        hideNativeCodexWhenOpenCodexPresent: Bool) -> [SpendSourcePublication]
    {
        let rosterSources = self.subscriptionRosterSources(for: provider)
            .filter { !hiddenSourceIDs.contains($0.id) }
        // Provider-specific by design: OpenCodex replaces Codex coverage only with a canonical Codex payload.
        guard provider == .codex else { return rosterSources }
        let visibleOpenCodexInputIDs: Set<String> = Set(self.inputs.compactMap { input -> String? in
            guard input.provider == .codex,
                  input.sourceKind == .openCodex,
                  !hiddenSourceIDs.contains(input.id)
            else { return nil }
            return input.id
        })
        let inputBackedEnrichmentSources = self.sources.filter {
            $0.provider == .codex &&
                $0.role == .enrichment &&
                visibleOpenCodexInputIDs.contains($0.id)
        }
        let canonicalReplacement = inputBackedEnrichmentSources.first {
            $0.id == SpendDashboardModel.openCodexSourceID
        }
        if hideNativeCodexWhenOpenCodexPresent,
           let canonicalReplacement,
           canonicalReplacement.state == SpendSourcePublication.State.available
        {
            return [canonicalReplacement]
        }
        if rosterSources.isEmpty, !inputBackedEnrichmentSources.isEmpty {
            return inputBackedEnrichmentSources
        }
        // Provider-specific by design: only canonical Codex enrichment can replace Codex subscription coverage.
        guard self.subscriptionRosterSources(for: provider).isEmpty,
              !hiddenSourceIDs.contains(SpendDashboardModel.openCodexSourceID),
              let openCodexObservation = self.sources.first(where: {
                  $0.id == SpendDashboardModel.openCodexSourceID &&
                      $0.provider == .codex &&
                      $0.role == .enrichment
              })
        else { return rosterSources }
        let hasCodexReplacementInput = self.inputs.contains {
            $0.id == SpendDashboardModel.openCodexSourceID &&
                $0.provider == .codex &&
                $0.sourceKind == .openCodex
        }
        return hasCodexReplacementInput || openCodexObservation.state == .confirmedEmpty
            ? [openCodexObservation]
            : rosterSources
    }
}
