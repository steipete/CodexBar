extension CostUsageScanner {
    static func preferredCLIProxyAPIAttribution(
        live: CostUsageAttribution,
        cached: CostUsageAttribution?) -> CostUsageAttribution
    {
        guard live.route == .cliProxyAPI,
              let cached,
              cached.route == .cliProxyAPI
        else { return live }
        if live.upstream == nil,
           cached.upstream != nil,
           cached.evidence.contains(.cliProxyUsageTelemetry)
        {
            return cached
        }
        guard live.client == cached.client,
              live.modelProvider == cached.modelProvider,
              live.upstream == cached.upstream
        else { return live }
        return CostUsageAttribution(
            client: live.client,
            route: live.route,
            modelProvider: live.modelProvider,
            upstream: live.upstream,
            evidence: Set(live.evidence).union(cached.evidence).sorted { $0.rawValue < $1.rawValue })
    }
}
