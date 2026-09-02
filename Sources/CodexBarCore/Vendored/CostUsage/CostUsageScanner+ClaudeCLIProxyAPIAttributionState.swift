extension CostUsageScanner {
    struct ClaudeCLIProxyAPIAttributionState {
        let configurationGeneration: String?
        let attributionEnabled: Bool
        let resolver: CLIProxyAPIAttributionResolver?
        let usageArtifactStamp: CostUsageClaudeFileStamp?
        let inputArtifactFingerprint: [String: CostUsageClaudeFileStamp]?
    }

    static func captureClaudeCLIProxyAPIAttributionState(
        options: Options,
        checkCancellation: CancellationCheck?) throws -> ClaudeCLIProxyAPIAttributionState
    {
        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: options.cacheRoot)
        {
            let configurationGeneration = CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                stateRoot: options.cacheRoot)
            let attributionEnabled = !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
                stateRoot: options.cacheRoot)
            let attributionResolver: CLIProxyAPIAttributionResolver?
            if attributionEnabled, let home = options.cliProxyAPIHome {
                let usageRecords = CLIProxyAPIUsageCacheIO.loadAssumingInterprocessLockHeld(
                    cacheRoot: options.cacheRoot)
                attributionResolver = try CLIProxyAPIAttributionResolver.load(
                    home: home,
                    cacheRoot: options.cacheRoot,
                    forceReload: options.forceRescan,
                    usageRecords: usageRecords,
                    checkCancellation: checkCancellation)
            } else {
                attributionResolver = nil
            }
            let usageArtifactStamp = CostUsageClaudeFileStamp.read(
                at: CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: options.cacheRoot))
            return ClaudeCLIProxyAPIAttributionState(
                configurationGeneration: configurationGeneration,
                attributionEnabled: attributionEnabled,
                resolver: attributionResolver,
                usageArtifactStamp: usageArtifactStamp,
                inputArtifactFingerprint: attributionResolver?.inputArtifactFingerprint)
        }
    }

    static func currentClaudeCLIProxyAPIInputArtifactFingerprint(
        options: Options,
        attributionEnabled: Bool,
        checkCancellation: CancellationCheck? = nil) throws -> [String: CostUsageClaudeFileStamp]?
    {
        guard attributionEnabled, let home = options.cliProxyAPIHome else { return nil }
        return try CLIProxyAPIAttributionResolver.inputArtifactFingerprint(
            home: home,
            checkCancellation: checkCancellation)
    }
}
