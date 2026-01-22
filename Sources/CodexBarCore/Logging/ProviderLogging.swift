public enum ProviderLogging {
    public static func logStartupState(
        logger: CodexBarLogger,
        providers: [UsageProvider],
        isEnabled: (UsageProvider) -> Bool,
        modeSnapshot: [String: String])
    {
        let ordered = providers.sorted { $0.rawValue < $1.rawValue }
        let states = ordered
            .map { provider -> String in
                let enabled = isEnabled(provider)
                return "\(provider.rawValue)=\(enabled ? "1" : "0")"
            }
            .joined(separator: ",")
        let enabledProviders = ordered
            .filter { isEnabled($0) }
            .map(\.rawValue)
            .joined(separator: ",")
        logger.info(
            "Provider enablement at startup",
            metadata: [
                "states": states,
                "enabled": enabledProviders.isEmpty ? "none" : enabledProviders,
            ])
        logger.info("Provider mode snapshot", metadata: modeSnapshot)
    }
}
