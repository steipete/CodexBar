import CodexBarCore

struct MenuOpenRefreshPlan: Equatable {
    struct Inputs {
        let refreshAllOnOpen: Bool
        let enabledProviders: [ProviderInstanceID]
        let visibleProviders: [ProviderInstanceID]
        let refreshingProviders: Set<ProviderInstanceID>
        let staleProviders: Set<ProviderInstanceID>
        let missingProviders: Set<ProviderInstanceID>
    }

    enum Scheduling: Equatable {
        case sequential
        case concurrent
    }

    let providers: [ProviderInstanceID]
    let scheduling: Scheduling
    let refreshCodexDashboard: Bool
    let refreshTokenCost: Bool

    static func resolve(_ inputs: Inputs) -> Self {
        if inputs.refreshAllOnOpen {
            return Self(
                providers: inputs.enabledProviders,
                scheduling: .concurrent,
                refreshCodexDashboard: inputs.enabledProviders.contains(.codex),
                refreshTokenCost: !inputs.enabledProviders.isEmpty)
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
            refreshCodexDashboard: false,
            refreshTokenCost: false)
    }
}
