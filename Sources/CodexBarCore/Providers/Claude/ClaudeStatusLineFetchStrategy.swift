import Foundation

/// Serves the 5h/7d windows a user-configured Claude statusLine command forwarded to CodexBar.
///
/// Opt-in and off by default. It joins the Auto order behind OAuth and ahead of the CLI probe, so it fills the
/// gap when the polled sources are cooling down or unavailable, and never pre-empts a successful OAuth read
/// (owner ruling, #2733).
struct ClaudeStatusLineFetchStrategy: ProviderFetchStrategy {
    typealias ObservationLoader = @Sendable (ProviderFetchContext) -> ClaudeStatusLineRateLimits?

    #if DEBUG
    @TaskLocal static var observationLoaderOverrideForTesting: ObservationLoader?
    #endif

    let id: String = "claude.statusline"
    /// Nearest existing kind: this reads an artifact the user's own tooling dropped on disk.
    let kind: ProviderFetchKind = .localProbe

    private let observationLoader: ObservationLoader?

    init(observationLoader: ObservationLoader? = nil) {
        self.observationLoader = observationLoader
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        self.loadObservation(context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let limits = self.loadObservation(context),
              let usage = ClaudeStatusLineDropStore.makeSnapshot(from: limits)
        else {
            // Absence, not an error: the user simply is not running Claude Code right now, or the payload
            // drifted. Falling through leaves the remaining planner steps to serve the card.
            throw ClaudeStatusLineFetchError.noFreshObservation
        }
        return self.makeResult(
            usage: claudeStatusLineUsageSnapshot(from: usage),
            sourceLabel: ClaudeUsageDataSource.statusline.sourceLabel)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // Always: this feed is supplementary by construction, so its absence must never end the chain.
        !ClaudeOAuthFetchError.isCancellation(error)
    }

    private func loadObservation(_ context: ProviderFetchContext) -> ClaudeStatusLineRateLimits? {
        #if DEBUG
        if let override = Self.observationLoaderOverrideForTesting {
            return override(context)
        }
        #endif
        if let observationLoader {
            return observationLoader(context)
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = ClaudeStatusLineDropStore.directoryURL(applicationSupport: support)
        return ClaudeStatusLineDropStore.select(
            candidates: ClaudeStatusLineDropStore.loadCandidates(directory: directory),
            expectedConfigDir: context.env[ClaudeConfigPaths.configDirectoryEnvironmentKey])
    }
}

enum ClaudeStatusLineFetchError: Error {
    case noFreshObservation
}
