import Foundation

/// Reads one Claude instance's quota through that instance's own Claude CLI.
public enum ClaudeInstanceUsageFetcher {
    public enum FetchError: LocalizedError, Equatable {
        case invalidConfigDirectory

        public var errorDescription: String? {
            switch self {
            case .invalidConfigDirectory:
                "Set an absolute Claude config directory for this instance."
            }
        }
    }

    public static func fetchUsage(
        for instance: ClaudeInstanceConfig,
        baseEnvironment: [String: String],
        browserDetection: BrowserDetection,
        keepCLISessionsAlive: Bool = false) async throws -> UsageSnapshot
    {
        guard let environment = ClaudeInstanceEnvironment.environment(for: instance, base: baseEnvironment) else {
            throw FetchError.invalidConfigDirectory
        }
        // CLI only: the instance's `claude` reads its own credentials, so CodexBar never touches the profile's
        // Keychain item. Browser-cookie extras stay off because cookies are not scoped to a Claude profile.
        let fetcher = ClaudeUsageFetcher(
            browserDetection: browserDetection,
            environment: environment,
            runtime: .app,
            dataSource: .cli,
            useWebExtras: false,
            keepCLISessionsAlive: keepCLISessionsAlive)
        let usage = try await fetcher.loadLatestUsage(model: "sonnet")
        return ClaudeOAuthFetchStrategy.snapshot(from: usage, dataConfidence: .percentOnly)
    }
}
