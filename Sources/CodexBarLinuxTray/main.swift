import CodexBarCore
import Dispatch
import Foundation

private struct ProviderRenderState: Sendable {
    let provider: UsageProvider
    let displayName: String
    let usage: UsageSnapshot?
    let credits: CreditsSnapshot?
    let error: String?
    let fetchedAt: Date
}

private final class LinuxTrayCoordinator: @unchecked Sendable {
    private let configStore = CodexBarConfigStore()
    private let runtimeConfigStore = LinuxTrayRuntimeConfigStore()
    private let fetcher = UsageFetcher()
    private let browserDetection = BrowserDetection()
    private let claudeFetcher: ClaudeUsageFetcher
    private let runtimeResolver: ProviderRuntimeResolver
    private let host: any LinuxTrayHost

    private var refreshToken: UInt64 = 0
    private var latestStates: [UsageProvider: ProviderRenderState] = [:]
    private var latestRefreshAt: Date?
    private var latestRuntimeConfig = LinuxTrayRuntimeConfig.default
    private var isRefreshing = false

    init(host: any LinuxTrayHost) {
        self.host = host
        self.claudeFetcher = ClaudeUsageFetcher(browserDetection: self.browserDetection)
        self.runtimeResolver = ProviderRuntimeResolver(
            credentials: CompositeProviderCredentialStore(stores: [
                EnvironmentProviderCredentialStore(),
                FileProviderCredentialStore(),
            ]))
    }

    func run() async {
        await self.host.start(onActivate: { [weak self] in
            Task { await self?.refreshNow() }
        })

        await self.refreshNow()
        while true {
            self.latestRuntimeConfig = self.runtimeConfigStore.load()
            let wait = UInt64(self.latestRuntimeConfig.refreshSeconds) * 1_000_000_000
            try? await Task.sleep(nanoseconds: wait)
            await self.refreshNow()
        }
    }

    private func refreshNow() async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        self.latestRuntimeConfig = self.runtimeConfigStore.load()
        self.refreshToken &+= 1
        let generation = self.refreshToken

        let config = (try? self.configStore.loadOrCreateDefault()) ?? CodexBarConfig.makeDefault()
        let metadata = ProviderDescriptorRegistry.metadata
        let providers = config.enabledProviders(metadata: metadata)

        let states = await self.fetchStates(providers: providers, config: config, metadata: metadata)
        if generation != self.refreshToken { return }

        self.latestStates = Dictionary(uniqueKeysWithValues: states.map { ($0.provider, $0) })
        self.latestRefreshAt = Date()

        let snapshot = WidgetSnapshot(
            entries: states.map { state in
                WidgetSnapshot.ProviderEntry(
                    provider: state.provider,
                    updatedAt: state.usage?.updatedAt ?? state.fetchedAt,
                    primary: state.usage?.primary,
                    secondary: state.usage?.secondary,
                    tertiary: state.usage?.tertiary,
                    creditsRemaining: state.credits?.remaining,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [])
            },
            enabledProviders: providers,
            generatedAt: Date())
        WidgetSnapshotStore.save(snapshot)

        let rendered = self.render(states: states, generatedAt: snapshot.generatedAt)
        await self.host.update(
            summary: rendered.summary,
            tooltip: rendered.tooltip,
            iconName: self.latestRuntimeConfig.iconName)
    }

    private func fetchStates(
        providers: [UsageProvider],
        config: CodexBarConfig,
        metadata: [UsageProvider: ProviderMetadata]) async -> [ProviderRenderState]
    {
        await withTaskGroup(of: ProviderRenderState.self, returning: [ProviderRenderState].self) { group in
            for provider in providers {
                group.addTask {
                    let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
                    let settings = config.providerConfig(for: provider)
                    let runtime = self.runtimeResolver.resolve(provider: provider, providerConfig: settings)
                    let context = ProviderFetchContext(
                        runtime: .app,
                        sourceMode: runtime.sourceMode,
                        includeCredits: true,
                        webTimeout: 60,
                        webDebugDumpHTML: false,
                        verbose: false,
                        env: runtime.env,
                        settings: nil,
                        fetcher: self.fetcher,
                        claudeFetcher: self.claudeFetcher,
                        browserDetection: self.browserDetection)
                    let outcome = await descriptor.fetchOutcome(context: context)
                    switch outcome.result {
                    case let .success(result):
                        return ProviderRenderState(
                            provider: provider,
                            displayName: metadata[provider]?.displayName ?? provider.rawValue.capitalized,
                            usage: result.usage.scoped(to: provider),
                            credits: result.credits,
                            error: nil,
                            fetchedAt: Date())
                    case let .failure(error):
                        return ProviderRenderState(
                            provider: provider,
                            displayName: metadata[provider]?.displayName ?? provider.rawValue.capitalized,
                            usage: nil,
                            credits: nil,
                            error: UsageFormatter.truncatedSingleLine(error.localizedDescription, max: 120),
                            fetchedAt: Date())
                    }
                }
            }

            var values: [ProviderRenderState] = []
            values.reserveCapacity(providers.count)
            for await state in group {
                values.append(state)
            }
            let indexMap = Dictionary(uniqueKeysWithValues: providers.enumerated().map { ($1, $0) })
            values.sort { (indexMap[$0.provider] ?? 0) < (indexMap[$1.provider] ?? 0) }
            return values
        }
    }

    private func render(states: [ProviderRenderState], generatedAt: Date) -> (summary: String, tooltip: String) {
        let errorCount = states.filter { $0.error != nil }.count
        let hasStaleData: Bool
        if let last = self.latestRefreshAt {
            let staleInterval = TimeInterval(self.latestRuntimeConfig.refreshSeconds * self.latestRuntimeConfig.staleAfterRefreshes)
            hasStaleData = Date().timeIntervalSince(last) > staleInterval
        } else {
            hasStaleData = true
        }

        let primary = states.first?.usage?.primary?.remainingPercent
        var summary = "CodexBar"
        if let primary {
            summary += String(format: " %.0f%%", max(0, primary))
        }
        if errorCount > 0 {
            summary += " !\(errorCount)"
        } else if hasStaleData {
            summary += " stale"
        }

        var lines: [String] = states.map { state in
            if let usage = state.usage {
                let session = usage.primary.map { String(format: "%.0f%%", max(0, $0.remainingPercent)) } ?? "--"
                let weekly = usage.secondary.map { String(format: "%.0f%%", max(0, $0.remainingPercent)) } ?? "--"
                let reset = usage.primary.flatMap {
                    UsageFormatter.resetLine(for: $0, style: .countdown)
                } ?? "Reset unknown"
                var row = "\(state.displayName): session \(session), weekly \(weekly), \(reset)"
                if let credits = state.credits?.remaining {
                    row += ", credits \(UsageFormatter.creditsString(from: credits))"
                }
                return row
            }
            return "\(state.displayName): error - \(state.error ?? "unknown")"
        }
        if lines.isEmpty {
            lines = ["No enabled providers. Edit ~/.codexbar/config.json to enable one."]
        }
        lines.append(UsageFormatter.updatedString(from: generatedAt))
        lines.append("Click tray icon to refresh now.")
        return (summary, lines.joined(separator: "\n"))
    }
}

private let hasZenity = ProcessInfo.processInfo.environment["CODEXBAR_TRAY_STDOUT_ONLY"] != "1"
    && FileManager.default.isExecutableFile(atPath: "/usr/bin/zenity")
private let host: any LinuxTrayHost = hasZenity ? ZenityTrayHost() : StdoutTrayHost()
private let coordinator = LinuxTrayCoordinator(host: host)
private let completion = DispatchSemaphore(value: 0)

Task {
    await coordinator.run()
    completion.signal()
}

completion.wait()
