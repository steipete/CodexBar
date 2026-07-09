import CodexBarCore

struct MenuOpenRefreshPlan: Equatable {
    struct Inputs {
        let refreshAllOnOpen: Bool
        let enabledProviders: [UsageProvider]
        let visibleProviders: [UsageProvider]
        let refreshingProviders: Set<UsageProvider>
        let staleProviders: Set<UsageProvider>
        let missingProviders: Set<UsageProvider>
        /// Providers whose hover prefetch just completed successfully; the refresh-all pass skips
        /// them so hover-then-open costs one refresh, not two.
        var hoverPrefetchedProviders: Set<UsageProvider> = []
    }

    enum Scheduling: Equatable {
        case sequential
        case concurrent
    }

    let providers: [UsageProvider]
    let scheduling: Scheduling
    let refreshCodexDashboard: Bool

    static func resolve(_ inputs: Inputs) -> Self {
        if inputs.refreshAllOnOpen {
            return Self(
                providers: inputs.enabledProviders.filter { !inputs.hoverPrefetchedProviders.contains($0) },
                scheduling: .concurrent,
                refreshCodexDashboard: inputs.enabledProviders.contains(.codex))
        }

        let enabled = Set(inputs.enabledProviders)
        let providers = inputs.visibleProviders.filter {
            enabled.contains($0) &&
                (inputs.refreshingProviders.contains($0) || inputs.staleProviders.contains($0) ||
                    inputs.missingProviders.contains($0))
        }
        return Self(
            providers: providers,
            scheduling: .sequential,
            refreshCodexDashboard: false)
    }
}
