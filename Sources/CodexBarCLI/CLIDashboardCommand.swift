import CodexBarCore
import Commander
import Foundation

struct DashboardOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Option(
        name: .long("timeout"),
        help: "Overall fetch timeout in seconds, 0...86400 (default 30; 0 disables)")
    var timeout: Double?
}

struct DashboardSnapshotResult {
    let payload: DashboardSnapshotPayload
    let usageCacheKeys: [String?]
}

/// Collects the stable dashboard-v1 payload independently of its transport.
/// The CLI command encodes it directly while `codexbar serve` wraps it in the
/// existing authenticated HTTP cache.
struct DashboardSnapshotProducer: Sendable {
    let collectUsage: @Sendable ([UsageProvider]) async throws -> UsageCommandOutput
    let collectCost: @Sendable ([UsageProvider], CodexBarConfig) async -> [CostPayload]
    let now: @Sendable () -> Date

    func collect(
        config: CodexBarConfig,
        refreshInterval: TimeInterval,
        codexBarVersion: String?) async throws -> DashboardSnapshotResult
    {
        let selection = CodexBarCLI.providerSelection(
            rawOverride: nil,
            enabled: config.enabledProviders())
        let usageOutput = try await self.collectUsage(selection.asList)
        let costPayloads = await self.collectCost(
            CodexBarCLI.costProviders(from: selection),
            config)

        let payload = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: usageOutput.payload,
            costPayloads: costPayloads,
            config: config,
            identityMode: .redacted,
            generatedAt: self.now(),
            refreshInterval: refreshInterval,
            codexBarVersion: codexBarVersion)
        return DashboardSnapshotResult(
            payload: payload,
            usageCacheKeys: usageOutput.payload.map(\.cacheAccountKey))
    }

    static func live(context: DashboardSnapshotContext) -> Self {
        Self(
            collectUsage: { providers in
                try await CodexBarCLI.serveUsageOutput(
                    selection: .custom(providers),
                    context: context.usage)
            },
            collectCost: { providers, config in
                let costFetcher = CostUsageFetcher()
                return await CodexBarCLI.collectConfiguredCostPayloads(
                    providers: providers,
                    config: config,
                    context: context.costCollection)
                { provider, cursorCookieHeaderOverride in
                    do {
                        let snapshot = try await costFetcher.loadTokenSnapshot(
                            provider: provider,
                            forceRefresh: false,
                            cursorCookieHeaderOverride: cursorCookieHeaderOverride,
                            refreshPricingInBackground: context.costRefreshesPricingInBackground)
                        return CodexBarCLI.makeCostPayload(provider: provider, snapshot: snapshot, error: nil)
                    } catch {
                        return CodexBarCLI.makeCostPayload(provider: provider, snapshot: nil, error: error)
                    }
                }
            },
            now: { Date() })
    }
}

extension CodexBarCLI {
    static let dashboardCostRefreshesPricingInBackground = false

    static func runDashboard(_ values: ParsedValues) async {
        guard let timeout = decodeDashboardTimeout(from: values) else {
            exit(
                code: .failure,
                message: "--timeout must be a finite number of seconds from 0 through 86400.",
                kind: .args)
        }

        let configSnapshot: CLIServeConfigSnapshot
        do {
            configSnapshot = try Self.loadServeConfigSnapshot()
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, kind: .config)
        }

        let providerOperations = CLIServeOperationCoordinator<UsageCommandOutput>()
        let costOperations = CLIServeOperationCoordinator<CostPayload>()
        let signalMonitor = CLITerminationSignalMonitor { signalNumber in
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signalNumber)
        }
        defer { signalMonitor.cancel() }

        let startedAt = ContinuousClock().now
        let providerTimeout = Self.serveProviderTimeout(requestTimeout: timeout)
        let context = DashboardSnapshotContext(
            config: configSnapshot.config,
            usage: ServeUsageContext(
                config: configSnapshot.config,
                configFingerprint: configSnapshot.cacheToken,
                refreshInterval: 0,
                providerTimeout: providerTimeout,
                providerDeadline: Self.serveProviderDeadline(
                    startedAt: startedAt,
                    requestTimeout: timeout),
                providerOperations: providerOperations,
                includeAllCodexAccounts: false,
                persistCLISessions: false),
            costCollection: ServeCostCollectionContext(
                configFingerprint: configSnapshot.cacheToken,
                providerTimeout: providerTimeout,
                requestDeadline: Self.serveRequestDeadline(
                    startedAt: startedAt,
                    requestTimeout: timeout),
                now: { ContinuousClock().now },
                providerOperations: costOperations),
            costRefreshesPricingInBackground: Self.dashboardCostRefreshesPricingInBackground,
            codexBarVersion: Self.currentVersion())

        let result: DashboardSnapshotResult
        do {
            result = try await DashboardSnapshotProducer.live(context: context).collect(
                config: context.config,
                refreshInterval: context.usage.refreshInterval,
                codexBarVersion: context.codexBarVersion)
        } catch {
            await Self.shutdownDashboardRuntime(
                providerOperations: providerOperations,
                costOperations: costOperations)
            Self.exit(code: .failure, message: error.localizedDescription)
        }

        await Self.shutdownDashboardRuntime(
            providerOperations: providerOperations,
            costOperations: costOperations)

        guard let json = Self.encodeJSON(result.payload, pretty: values.flags.contains("pretty")) else {
            Self.exit(code: .failure, message: "Could not encode dashboard snapshot.")
        }
        print(json)
    }

    static func decodeDashboardTimeout(from values: ParsedValues) -> TimeInterval? {
        let raw = values.options["timeout"]?.last ?? String(Int(Self.defaultServeRequestTimeout))
        guard let timeout = TimeInterval(raw),
              timeout.isFinite,
              timeout >= 0,
              timeout <= 86400
        else {
            return nil
        }
        return timeout
    }

    private static func shutdownDashboardRuntime(
        providerOperations: CLIServeOperationCoordinator<UsageCommandOutput>,
        costOperations: CLIServeOperationCoordinator<CostPayload>) async
    {
        await providerOperations.shutdown()
        await costOperations.shutdown()
        await ProviderCLISessionLifecycle.shutdownPersistentSessions()
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
    }
}
