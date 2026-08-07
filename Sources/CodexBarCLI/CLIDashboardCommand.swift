#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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

    @Option(
        name: .long("identity"),
        help: "Account identity detail: redacted (default) or full. The HTTP serve transport is always " +
            "redacted; full is for one-shot snapshots consumed on trusted, private surfaces.")
    var identity: String?

    @Option(
        name: .long("output"),
        help: "Write the snapshot atomically to this file (0644) instead of stdout. " +
            "The parent directory must already exist; it is not created.")
    var output: String?
}

struct DashboardSnapshotResult {
    let payload: DashboardSnapshotPayload
    let usageCacheKeys: [String?]
}

struct DashboardClaudeSwapCollection: Sendable {
    let accounts: [ProviderAccountUsageSnapshot]?
    let adapterError: String?
}

/// Collects the stable dashboard-v1 payload independently of its transport.
/// The CLI command encodes it directly while `codexbar serve` wraps it in the
/// existing authenticated HTTP cache.
struct DashboardSnapshotProducer: Sendable {
    let collectUsage: @Sendable ([UsageProvider]) async throws -> UsageCommandOutput
    let collectCost: @Sendable ([UsageProvider], CodexBarConfig) async -> [CostPayload]
    let now: @Sendable () -> Date
    var collectClaudeSwapAccounts: @Sendable (CodexBarConfig) async -> DashboardClaudeSwapCollection? = { _ in nil }
    var weeklyWorkDays: @Sendable () -> Int? = { nil }

    func collect(
        config: CodexBarConfig,
        refreshInterval: TimeInterval,
        codexBarVersion: String?,
        identityMode: DashboardIdentityMode = .redacted,
        providers requestedProviders: [UsageProvider]? = nil) async throws -> DashboardSnapshotResult
    {
        let selection = requestedProviders.map(ProviderSelection.custom) ?? CodexBarCLI.providerSelection(
            rawOverride: nil,
            enabled: config.enabledProviders().compactMap(\.firstPartyProvider))
        let usageOutput = try await self.collectUsage(selection.asList)
        let costPayloads = await self.collectCost(
            CodexBarCLI.costProviders(from: selection),
            config)
        // Provider-specific by design: claude-swap account enrichment is a
        // Claude-only integration, so provider-filtered snapshots skip it
        // unless the Claude row is requested.
        let claudeSwap = selection.asList.contains(.claude)
            ? await self.collectClaudeSwapAccounts(config)
            : nil
        let generatedAt = self.now()

        let payload = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: usageOutput.payload,
            costPayloads: costPayloads,
            config: config,
            identityMode: identityMode,
            generatedAt: generatedAt,
            refreshInterval: refreshInterval,
            codexBarVersion: codexBarVersion,
            claudeSwap: claudeSwap.map {
                DashboardClaudeSwapInput(
                    accounts: $0.accounts,
                    adapterError: $0.adapterError,
                    weeklyWorkDays: self.weeklyWorkDays())
            })
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
            now: { Date() },
            collectClaudeSwapAccounts: { config in
                // Provider-specific by design: the dashboard opts into Claude's local multi-account adapter.
                guard CodexBarCLI.dashboardClaudeSwapIsEligible(config: config) else { return nil }
                let path = config.providerConfig(for: .claude)?.sanitizedClaudeSwapExecutablePath ?? ""
                let timeout = min(
                    ClaudeSwapAccountReader.defaultTimeout,
                    context.usage.providerTimeout ?? ClaudeSwapAccountReader.defaultTimeout)
                do {
                    let list = try await ClaudeSwapAccountReader.readAccountList(
                        executablePath: path,
                        timeout: timeout)
                    return DashboardClaudeSwapCollection(
                        accounts: ClaudeSwapAccountProjection.accountSnapshots(from: list),
                        adapterError: nil)
                } catch {
                    let diagnostic = CLIClaudeSwapText.sanitizeDiagnostic(error.localizedDescription)
                    return DashboardClaudeSwapCollection(
                        accounts: nil,
                        adapterError: diagnostic.isEmpty ? "claude-swap list failed." : diagnostic)
                }
            },
            weeklyWorkDays: { CodexBarCLI.weeklyProgressWorkDaysFromDefaults() })
    }
}

extension CodexBarCLI {
    static let dashboardCostRefreshesPricingInBackground = false

    /// Dashboard-only claude-swap eligibility: Claude enabled and the integration switched on.
    /// (Cards have their own eligibility in CLIClaudeSwapCards; serve /usage stays untouched.)
    static func dashboardClaudeSwapIsEligible(config: CodexBarConfig) -> Bool {
        // Provider-specific by design: only enabled Claude rows can expose claude-swap accounts.
        config.enabledProviders().compactMap(\.firstPartyProvider).contains(.claude)
            && config.providerConfig(for: .claude)?.claudeSwapEnabled == true
    }

    static func runDashboard(_ values: ParsedValues) async {
        guard let timeout = decodeDashboardTimeout(from: values) else {
            exit(
                code: .failure,
                message: "--timeout must be a finite number of seconds from 0 through 86400.",
                kind: .args)
        }
        guard let identityMode = decodeDashboardIdentityMode(from: values) else {
            exit(
                code: .failure,
                message: "--identity must be redacted or full.",
                kind: .args)
        }
        guard let outputDestination = decodeDashboardOutputDestination(from: values) else {
            exit(
                code: .failure,
                message: "--output requires a non-empty file path.",
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
                codexBarVersion: context.codexBarVersion,
                identityMode: identityMode)
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
        switch outputDestination {
        case .stdout:
            print(json)
        case let .file(path):
            do {
                // Match stdout shape: the published document ends with a newline.
                try Self.writeDashboardSnapshotAtomically(Data((json + "\n").utf8), toPath: path)
            } catch {
                Self.exit(code: .failure, message: error.localizedDescription)
            }
        }
    }

    enum DashboardOutputDestination: Equatable {
        case stdout
        case file(String)
    }

    /// `nil` means the flag was given with an empty path (an args error);
    /// an absent flag keeps the historical stdout behavior.
    static func decodeDashboardOutputDestination(from values: ParsedValues) -> DashboardOutputDestination? {
        guard let raw = values.options["output"]?.last else { return .stdout }
        guard !raw.isEmpty else { return nil }
        return .file(raw)
    }

    /// Atomically publish the snapshot: stage a temp file in the destination
    /// directory, fsync, then `rename(2)` over the target so readers (e.g. a
    /// static webroot) never observe a partial document. The file is world-
    /// readable (`0644`) — dashboard snapshots are meant to be served. The
    /// parent directory must already exist; it is deliberately not created.
    static func writeDashboardSnapshotAtomically(_ data: Data, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey:
                        "--output directory does not exist: \(directory.path) (parent directories are not created)",
                ])
        }

        let staged = directory.appendingPathComponent(
            ".\(url.lastPathComponent).codexbar-dashboard-\(UUID().uuidString)", isDirectory: false)
        let descriptor = staged.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o644))
        }
        guard descriptor >= 0 else { throw Self.dashboardOutputPOSIXError(errno, path: staged.path) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var handleOpen = true
        do {
            // Force 0644 even if umask narrowed the O_CREAT mode.
            guard fchmod(descriptor, mode_t(0o644)) == 0 else {
                throw Self.dashboardOutputPOSIXError(errno, path: staged.path)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            handleOpen = false

            let renamed = staged.path.withCString { src in
                url.path.withCString { dst in rename(src, dst) }
            }
            guard renamed == 0 else { throw Self.dashboardOutputPOSIXError(errno, path: url.path) }
        } catch {
            if handleOpen { try? handle.close() }
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    private static func dashboardOutputPOSIXError(_ code: Int32, path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "Could not write --output file \(path): \(String(cString: strerror(code)))",
            ])
    }

    /// `.none` is deliberately not accepted: the flag chooses between the safe
    /// default and full identity for trusted local consumers; suppressing
    /// identity entirely is not a supported dashboard shape.
    static func decodeDashboardIdentityMode(from values: ParsedValues) -> DashboardIdentityMode? {
        guard let raw = values.options["identity"]?.last else { return .redacted }
        switch raw.lowercased() {
        case DashboardIdentityMode.redacted.rawValue:
            return .redacted
        case DashboardIdentityMode.full.rawValue:
            return .full
        default:
            return nil
        }
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
