import Foundation

public enum AntigravityProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Google accounts",
        subtitle: "Store multiple Antigravity Google OAuth accounts for quick switching.",
        placeholder: "Antigravity OAuth credentials JSON",
        injection: .environment(key: AntigravityOAuthCredentialsStore.environmentCredentialsKey),
        requiresManualCookieSource: false,
        cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .antigravity,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .antigravity,
                displayName: "Antigravity",
                shortDisplayName: "Anti",
                sessionLabel: "Gemini Models",
                weeklyLabel: "Claude and GPT",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Antigravity usage (experimental)",
                cliName: "antigravity",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "paid": "Paid", "pro": "Pro",
                    "ultra": "Google AI Ultra", "google ai ultra": "Google AI Ultra",
                ],
                debugLogUnavailableMessage: "Antigravity debug log not yet implemented",
                debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 3),
                dashboardURL: nil,
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .antigravity),
                iconResourceName: "ProviderIcon-antigravity",
                color: ProviderColor(red: 96 / 255, green: 186 / 255, blue: 126 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4285F4),
                    ProviderColor(hex: 0x34A853),
                    ProviderColor(hex: 0xFBBC04),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Antigravity cost summary is not supported." },
                supportsTokenSnapshot: true),
            pace: ProviderPaceCapability(
                sessionPaceWindowRule: .custom { window, _ in
                    window.windowMinutes == nil || window.windowMinutes == 300
                }),
            history: .alwaysTracked,
            presentation: ProviderUsagePresentation(
                iconWindowResolver: self.iconWindows,
                // Provider-specific by design: Antigravity decorates its mixed-model usage with the Gemini badge.
                iconDecorations: [.gemini, .antigravity],
                semanticWindowResolver: self.semanticWindows,
                requestedMenuBarLaneOrders: [
                    .primary: [.primary, .secondary, .tertiary],
                    .secondary: [.secondary, .primary, .tertiary],
                    .tertiary: [.tertiary, .secondary, .primary],
                ],
                automaticSelectionPrioritizesExhaustedWindow: false,
                menuBarWindowResolver: self.menuBarWindow,
                widgetRowLimitResolver: { rows, family in
                    guard rows?.contains(where: { $0.id.hasPrefix(Self.quotaSummaryPrefix) }) == true else {
                        return nil
                    }
                    return family == .small ? 2 : 3
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline(
                    resolveStrategies: self.resolveStrategies,
                    resolveFallbackError: self.resolveFallbackError)),
            cli: ProviderCLIConfig(
                name: "antigravity",
                versionDetector: nil))
    }

    private static let quotaSummaryPrefix = "antigravity-quota-summary-"
    private static let compactFallbackPrefix = "antigravity-compact-fallback-"

    private static func semanticWindows(snapshot: UsageSnapshot) -> ProviderSemanticWindows {
        let rows = (snapshot.extraRateWindows ?? []).filter { $0.id.hasPrefix(self.quotaSummaryPrefix) }
        guard !rows.isEmpty else {
            return ProviderUsagePresentation.standardSemanticWindows(snapshot: snapshot)
        }
        // Family representatives can use different cadences; unavailable summary lanes must stay unavailable.
        let known = rows.filter(\.usageKnown)
        return ProviderSemanticWindows(
            session: self.mostConstrained(windows: known, minutes: 300),
            weekly: self.mostConstrained(windows: known, minutes: 7 * 24 * 60))
    }

    private static func iconWindows(context: ProviderIconWindowContext) -> ProviderUsageWindowPair {
        let windows = (context.snapshot.extraRateWindows ?? [])
            .filter { $0.usageKnown && $0.id.hasPrefix(self.quotaSummaryPrefix) }
        guard !windows.isEmpty else { return ProviderUsageWindowPair(primary: nil, secondary: nil) }
        return ProviderUsageWindowPair(
            primary: self.mostConstrained(windows: windows, minutes: 300),
            secondary: self.mostConstrained(windows: windows, minutes: 7 * 24 * 60))
    }

    private static func mostConstrained(windows: [NamedRateWindow], minutes: Int) -> RateWindow? {
        windows
            .filter { $0.window.windowMinutes == minutes }
            .max { lhs, rhs in
                if lhs.window.usedPercent != rhs.window.usedPercent {
                    return lhs.window.usedPercent < rhs.window.usedPercent
                }
                return lhs.id > rhs.id
            }?
            .window
    }

    private static func menuBarWindow(
        context: ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution
    {
        switch context.metric {
        case .primary, .secondary, .tertiary:
            let order = self.descriptor.presentation.requestedMenuBarLaneOrder(for: context.metric)
            return .resolved(
                ProviderUsagePresentation.window(in: context.snapshot, following: order)
                    ?? self.mostConstrainedExtraWindow(
                        snapshot: context.snapshot,
                        prefix: self.compactFallbackPrefix))
        case .average where !context.supportsAverage:
            return .resolved(ProviderUsagePresentation.window(
                in: context.snapshot,
                following: [.primary, .secondary, .tertiary]))
        case .automatic:
            if context.prioritizesExhaustedQuotas,
               let ranked = self.rankedQuotaSummaryWindow(snapshot: context.snapshot, now: context.now)
            {
                return .resolved(ranked)
            }
            return .resolved(
                self.mostConstrainedExtraWindow(snapshot: context.snapshot, prefix: self.quotaSummaryPrefix)
                    ?? ProviderUsagePresentation.mostConstrained(
                        context.snapshot.primary,
                        context.snapshot.secondary,
                        context.snapshot.tertiary)
                    ?? self.mostConstrainedExtraWindow(
                        snapshot: context.snapshot,
                        prefix: self.compactFallbackPrefix))
        default:
            return .unhandled
        }
    }

    private static func mostConstrainedExtraWindow(snapshot: UsageSnapshot, prefix: String) -> RateWindow? {
        let windows = (snapshot.extraRateWindows ?? [])
            .filter { $0.usageKnown && $0.id.hasPrefix(prefix) }
            .map(\.window)
        let usable = windows.filter { $0.usedPercent < 100 }
        return (usable.isEmpty ? windows : usable).max(by: { $0.usedPercent < $1.usedPercent })
    }

    private static func rankedQuotaSummaryWindow(snapshot: UsageSnapshot, now: Date) -> RateWindow? {
        (snapshot.extraRateWindows ?? [])
            .filter {
                $0.usageKnown &&
                    $0.id.hasPrefix(self.quotaSummaryPrefix) &&
                    $0.window.usedPercent.isFinite &&
                    [300, 7 * 24 * 60].contains($0.window.windowMinutes)
            }
            .max { lhs, rhs in
                if lhs.window.usedPercent != rhs.window.usedPercent {
                    return lhs.window.usedPercent < rhs.window.usedPercent
                }
                let lhsReset = lhs.window.resetsAt.flatMap { $0 > now ? $0 : nil }
                let rhsReset = rhs.window.resetsAt.flatMap { $0 > now ? $0 : nil }
                if (lhsReset == nil) != (rhsReset == nil) {
                    return lhsReset == nil
                }
                if let lhsReset, let rhsReset, lhsReset != rhsReset {
                    return lhsReset > rhsReset
                }
                return lhs.id < rhs.id
            }?
            .window
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let app = AntigravityStatusFetchStrategy(source: .app)
        let cli = AntigravityCLIHTTPSFetchStrategy()
        let ide = AntigravityStatusFetchStrategy(source: .ide)
        let oauth = AntigravityOAuthFetchStrategy()
        let offline = AntigravityOfflineFetchStrategy()
        switch context.sourceMode {
        case .cli:
            return [app, cli, ide, offline]
        case .oauth:
            return [oauth]
        case .auto:
            if context.selectedTokenAccountID != nil ||
                context.env[AntigravityOAuthCredentialsStore.environmentCredentialsKey] != nil ||
                self.hasSharedOAuthCredentials(context: context)
            {
                return [app, cli, ide, oauth, offline]
            }
            return [app, cli, ide, offline]
        case .web, .api:
            return []
        }
    }

    private static func hasSharedOAuthCredentials(context: ProviderFetchContext) -> Bool {
        let homeURL = context.env["HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fileURL = AntigravityOAuthCredentialsStore.defaultURL(home: homeURL)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func resolveFallbackError(_ previous: Error?, _ current: Error) -> Error {
        if (previous as? AntigravityStatusProbeError) == .authenticationRequired,
           (current as? AntigravityStatusProbeError) == .notRunning
        {
            return previous ?? current
        }
        return current
    }
}

struct AntigravityStatusFetchStrategy: ProviderFetchStrategy {
    enum Source {
        case app
        case ide

        var id: String {
            switch self {
            case .app: "antigravity.app-local"
            case .ide: "antigravity.ide-local"
            }
        }

        var processScope: AntigravityStatusProbe.ProcessScope {
            switch self {
            case .app: .appOnly
            case .ide: .ideOnly
            }
        }

        var sourceLabel: String {
            switch self {
            case .app: "app"
            case .ide: "ide"
            }
        }
    }

    let source: Source
    var id: String {
        self.source.id
    }

    let kind: ProviderFetchKind = .localProbe

    init(source: Source = .app) {
        self.source = source
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AntigravityStatusProbe(processScope: self.source.processScope)
        let selectedAccountEmail: String? = if context.sourceMode == .auto, context.selectedTokenAccountID != nil {
            AntigravitySelectedAccountGuard.selectedAccountEmail(context: context)
        } else {
            nil
        }
        let snap = try await probe.fetch(matchingAccountEmail: selectedAccountEmail)
        let usage = try snap.toUsageSnapshot()
        try AntigravitySelectedAccountGuard.validate(usage, context: context)
        return self.makeResult(
            usage: usage,
            sourceLabel: self.source.sourceLabel)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto || context.sourceMode == .cli
    }
}

/// When the Antigravity 2.0 app is closed or unavailable, this strategy spawns
/// or reuses ``agy`` and talks to the localhost server embedded in that CLI
/// process. ``agy`` is an interactive REPL, not a query command, so CodexBar
/// never scrapes TUI output here; it only keeps the process alive long enough
/// for the server to answer quota endpoints.
struct AntigravityCLIHTTPSFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "cli"
    let id: String = "antigravity.cli-https"
    let kind: ProviderFetchKind = .cli
    private static let log = CodexBarLog.logger(LogCategories.provider(.antigravity))

    struct SnapshotWaitDependencies {
        let pollIntervalNanoseconds: UInt64
        let listeningPorts: @Sendable (Int, TimeInterval) async throws -> [Int]
        let drainOutput: @Sendable () async -> Data
        let fetchSnapshot: @Sendable ([Int]) async throws -> AntigravityStatusSnapshot
        let now: @Sendable () -> Date

        init(
            pollIntervalNanoseconds: UInt64,
            listeningPorts: @escaping @Sendable (Int, TimeInterval) async throws -> [Int],
            drainOutput: @escaping @Sendable () async -> Data,
            fetchSnapshot: @escaping @Sendable ([Int]) async throws -> AntigravityStatusSnapshot,
            now: @escaping @Sendable () -> Date = Date.init)
        {
            self.pollIntervalNanoseconds = pollIntervalNanoseconds
            self.listeningPorts = listeningPorts
            self.drainOutput = drainOutput
            self.fetchSnapshot = fetchSnapshot
            self.now = now
        }
    }

    /// Seams for discovering and reusing an already-running ``agy`` CLI language
    /// server, so a fresh spawn (and its multi-second ``GetUserStatus`` warm-up)
    /// can be skipped when a warm server is already present.
    struct WarmAgyDependencies {
        let processInfos: @Sendable (TimeInterval) async throws -> [AntigravityStatusProbe.ProcessInfoResult]
        let listeningPorts: @Sendable (Int, TimeInterval) async throws -> [Int]
        let fetchSnapshot: @Sendable ([Int], TimeInterval) async throws -> AntigravityStatusSnapshot
        let processOwnerUserID: @Sendable (Int) -> UInt32?
        let currentUserID: @Sendable () -> UInt32
        /// The pid of an ``agy`` that CodexBar itself spawned and manages through
        /// ``AntigravityCLISession`` (if any). Such a process must NOT be reused
        /// through the warm path: doing so bypasses `beginProbe`/`finishProbe`, so
        /// the idle timer is never cancelled/extended and `stopIfIdle` could tear
        /// the managed session down mid-poll. Externally owned `agy` (an IDE, a
        /// long-lived `agy`, or another CodexBar host) has no such accounting.
        let ownedPID: @Sendable () async -> Int?
        let now: @Sendable () -> Date

        init(
            processInfos: @escaping @Sendable (TimeInterval) async throws
                -> [AntigravityStatusProbe.ProcessInfoResult],
            listeningPorts: @escaping @Sendable (Int, TimeInterval) async throws -> [Int],
            fetchSnapshot: @escaping @Sendable ([Int], TimeInterval) async throws -> AntigravityStatusSnapshot,
            processOwnerUserID: @escaping @Sendable (Int) -> UInt32? = { _ in 0 },
            currentUserID: @escaping @Sendable () -> UInt32 = { 0 },
            ownedPID: @escaping @Sendable () async -> Int? = { nil },
            now: @escaping @Sendable () -> Date = Date.init)
        {
            self.processInfos = processInfos
            self.listeningPorts = listeningPorts
            self.fetchSnapshot = fetchSnapshot
            self.processOwnerUserID = processOwnerUserID
            self.currentUserID = currentUserID
            self.ownedPID = ownedPID
            self.now = now
        }
    }

    /// Discover an already-running, authenticated ``agy`` CLI language server and
    /// reuse its listening ports instead of spawning a fresh process.
    ///
    /// One-shot CLI invocations otherwise spawn a brand-new ``agy`` on every
    /// call; a fresh server binds its port quickly but ``GetUserStatus`` returns
    /// transient initialization failures for a few seconds, so the readiness
    /// deadline is occasionally missed. When a warm CLI server is already up, we
    /// can talk to it immediately — it needs no CSRF token (``cliHTTPS``).
    ///
    /// Returns the snapshot from the first warm server that answers with
    /// parseable usage for the requested account, or `nil` when none is found or
    /// none answers — in which case the caller falls back to the existing spawn
    /// path unchanged.
    static func tryWarmAgyFetch(
        timeout: TimeInterval,
        expectedBinaryPath: String? = nil,
        expectedAccountEmail: String? = nil,
        dependencies: WarmAgyDependencies) async throws -> AntigravityStatusSnapshot?
    {
        try Task.checkCancellation()
        let deadline = dependencies.now().addingTimeInterval(timeout)
        guard let discoveryTimeout = Self.remainingWarmProbeTime(deadline: deadline, now: dependencies.now) else {
            return nil
        }
        let processInfos: [AntigravityStatusProbe.ProcessInfoResult]
        do {
            processInfos = try await dependencies.processInfos(discoveryTimeout)
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
        try Task.checkCancellation()
        let ownedPID = await dependencies.ownedPID()
        try Task.checkCancellation()
        let currentUserID = dependencies.currentUserID()
        // Only the CLI's language server needs no CSRF token; the IDE/app servers
        // require one and must not be reused through this token-less fast path.
        // Also exclude any `agy` CodexBar itself spawned and manages: reusing it
        // here would bypass session lifecycle accounting (see `ownedPID`).
        let cliProcesses = processInfos.filter { info in
            info.pid != ownedPID &&
                dependencies.processOwnerUserID(info.pid) == currentUserID &&
                AntigravityStatusProbe.antigravityProcessKind(info.commandLine) == .cli
        }
        guard !cliProcesses.isEmpty else { return nil }

        for info in cliProcesses {
            if let expectedBinaryPath {
                guard Self.commandLine(info.commandLine, matchesBinaryPath: expectedBinaryPath)
                else {
                    continue
                }
            }
            guard let portTimeout = Self.remainingWarmProbeTime(deadline: deadline, now: dependencies.now) else {
                return nil
            }
            let ports: [Int]
            do {
                ports = try await dependencies.listeningPorts(info.pid, portTimeout)
            } catch let error as CancellationError {
                throw error
            } catch {
                continue
            }
            try Task.checkCancellation()
            guard !ports.isEmpty else { continue }
            guard let fetchTimeout = Self.remainingWarmProbeTime(deadline: deadline, now: dependencies.now) else {
                return nil
            }
            let snapshot: AntigravityStatusSnapshot
            do {
                snapshot = try await dependencies.fetchSnapshot(ports, fetchTimeout)
            } catch let error as CancellationError {
                throw error
            } catch {
                continue
            }
            try Task.checkCancellation()
            guard (try? snapshot.toUsageSnapshot()) != nil,
                  AntigravitySelectedAccountGuard.matches(
                      snapshotAccountEmail: snapshot.accountEmail,
                      expectedAccountEmail: expectedAccountEmail)
            else {
                continue
            }
            Self.log.debug("Antigravity CLI HTTPS reusing warm agy", metadata: [
                "pid": "\(info.pid)",
                "ports": ports.map(String.init).joined(separator: ","),
            ])
            return snapshot
        }
        try Task.checkCancellation()
        return nil
    }

    private static func remainingWarmProbeTime(
        deadline: Date,
        now: @Sendable () -> Date) -> TimeInterval?
    {
        let remaining = deadline.timeIntervalSince(now())
        return remaining > 0 ? remaining : nil
    }

    private static func commandLine(_ commandLine: String, matchesBinaryPath binaryPath: String) -> Bool {
        let candidates = [
            URL(fileURLWithPath: binaryPath).standardizedFileURL.path,
            URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        return candidates.contains { candidate in
            commandLine == candidate || commandLine.hasPrefix("\(candidate) ")
        }
    }

    /// Production wiring for ``tryWarmAgyFetch``: list processes via `ps`, find
    /// listening ports via `lsof`, and probe the token-less CLI HTTPS endpoint.
    static func liveWarmAgyDependencies() -> WarmAgyDependencies {
        WarmAgyDependencies(
            processInfos: { timeout in
                // A missing-CSRF/notRunning throw means no reusable server; the
                // caller maps any throw to "no warm agy" and spawns instead.
                try await AntigravityStatusProbe.detectProcessInfos(
                    timeout: timeout,
                    scope: .ideAndCLI)
            },
            listeningPorts: { pid, timeout in
                try await AntigravityStatusProbe.listeningPorts(pid: pid, timeout: timeout)
            },
            fetchSnapshot: { ports, timeout in
                let deadline = Date().addingTimeInterval(timeout)
                return try await AntigravityStatusProbe(timeout: timeout)
                    .fetchFromPorts(ports, deadline: deadline)
            },
            processOwnerUserID: { pid in
                AntigravityProcessIdentityProvider().ownerUserID(for: pid_t(pid))
            },
            currentUserID: {
                AntigravityProcessIdentityProvider.currentUserID
            },
            ownedPID: {
                // The pid of the `agy` CodexBar manages through the shared
                // session, so the warm scan never reuses our own process.
                await AntigravityCLISession.shared.pid.map(Int.init)
            })
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveAntigravityBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let binary = BinaryLocator.resolveAntigravityBinary(env: context.env) else {
            throw AntigravityStatusProbeError.notRunning
        }
        let expectedAccountEmail: String? = if context.sourceMode == .auto,
                                               context.selectedTokenAccountID != nil
        {
            AntigravitySelectedAccountGuard.selectedAccountEmail(context: context)
        } else {
            nil
        }
        let result = try await self.fetchUsingWarmSession(
            binary: binary,
            idleWindow: context.persistentCLISessionIdleWindow,
            resetAfterFetch: Self.shouldResetSessionAfterFetch(context),
            expectedAccountEmail: expectedAccountEmail)
        try AntigravitySelectedAccountGuard.validate(result.usage, context: context)
        return result
    }

    private func fetchUsingWarmSession(
        binary: String,
        idleWindow: TimeInterval?,
        resetAfterFetch: Bool,
        expectedAccountEmail: String?) async throws -> ProviderFetchResult
    {
        try await self.fetchUsingWarmSession(
            binary: binary,
            idleWindow: idleWindow,
            resetAfterFetch: resetAfterFetch,
            expectedAccountEmail: expectedAccountEmail,
            warmDependencies: Self.liveWarmAgyDependencies(),
            spawnFetch: { binary, idleWindow, resetAfterFetch in
                try await self.fetchBySpawning(
                    binary: binary,
                    idleWindow: idleWindow,
                    resetAfterFetch: resetAfterFetch,
                    expectedAccountEmail: expectedAccountEmail)
            })
    }

    /// Testable core of the CLI fetch: try the warm-reuse fast path first, then
    /// fall back to spawning. The `spawnFetch` seam lets tests assert the spawn
    /// path is skipped when a warm server is reused.
    func fetchUsingWarmSession(
        binary: String,
        idleWindow: TimeInterval?,
        resetAfterFetch: Bool,
        expectedAccountEmail: String? = nil,
        warmDependencies: WarmAgyDependencies,
        spawnFetch: @Sendable (String, TimeInterval?, Bool) async throws -> ProviderFetchResult)
        async throws -> ProviderFetchResult
    {
        // Fast path: reuse an already-running, authenticated `agy` CLI server if
        // one is present, avoiding a fresh spawn and its multi-second warm-up.
        // When none is found (or none answers), fall through to the spawn path.
        //
        // The warm path deliberately does NOT touch `AntigravityCLISession`
        // (`beginProbe`/`finishProbe`): a discovered `agy` is owned by another
        // process (an IDE, a long-lived `agy`, or another CodexBar host), so
        // CodexBar must not manage its lifecycle, idle timeout, or
        // `resetAfterFetch` teardown. Those apply only to processes CodexBar
        // itself spawns on the fallback path below.
        // Persistent hosts also need the external path: a user-owned, signed-in
        // `agy` may have credentials a newly spawned managed session cannot read.
        // Owned pids remain excluded, so their lifecycle accounting is unchanged.
        if let warmSnapshot = try await Self.tryWarmAgyFetch(
            timeout: 2.0,
            expectedBinaryPath: binary,
            expectedAccountEmail: expectedAccountEmail,
            dependencies: warmDependencies)
        {
            // `tryWarmAgyFetch` only returns a snapshot whose `toUsageSnapshot()`
            // already succeeded, so this conversion must not silently fail.
            let warmUsage = try warmSnapshot.toUsageSnapshot()
            return self.makeResult(
                usage: warmUsage,
                sourceLabel: Self.sourceLabel)
        }

        try Task.checkCancellation()
        return try await spawnFetch(binary, idleWindow, resetAfterFetch)
    }

    /// Spawn (or reuse CodexBar's own warm) `agy` session and wait for the CLI
    /// HTTPS endpoint to report ready. This is the original behavior, unchanged.
    private func fetchBySpawning(
        binary: String,
        idleWindow: TimeInterval?,
        resetAfterFetch: Bool,
        expectedAccountEmail: String?) async throws -> ProviderFetchResult
    {
        let session = AntigravityCLISession.shared
        let pid = try await session.beginProbe(binary: binary, idleWindow: idleWindow)
        // Fresh `agy` processes take a few seconds to complete macOS keyring
        // authentication, then more time before quota endpoints answer. A 5s
        // window reliably missed that cold-start window in live tests, so keep
        // the readiness deadline long enough for a cold spawn.
        let deadline = Date().addingTimeInterval(15.0)
        let snap: AntigravityStatusSnapshot
        let usage: UsageSnapshot
        do {
            snap = try await Self.waitForSnapshot(
                pid: pid,
                deadline: deadline,
                expectedAccountEmail: expectedAccountEmail,
                dependencies: SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 200_000_000,
                    listeningPorts: { pid, timeout in
                        try await AntigravityStatusProbe.listeningPorts(pid: pid, timeout: timeout)
                    },
                    drainOutput: {
                        await session.drainOutput()
                    },
                    fetchSnapshot: { ports in
                        let timeout = min(2.0, max(0.2, deadline.timeIntervalSinceNow))
                        return try await AntigravityStatusProbe(timeout: timeout)
                            .fetchFromPorts(ports, deadline: deadline)
                    }))
            usage = try snap.toUsageSnapshot()
            await session.finishProbe(success: true, resetAfterFetch: resetAfterFetch)
        } catch {
            let authenticationRequired = (error as? AntigravityStatusProbeError) == .authenticationRequired
            await session.finishProbe(
                success: false,
                resetAfterFetch: resetAfterFetch || authenticationRequired,
                forceTerminate: authenticationRequired)
            throw error
        }

        return self.makeResult(
            usage: usage,
            sourceLabel: Self.sourceLabel)
    }

    static func shouldResetSessionAfterFetch(_ context: ProviderFetchContext) -> Bool {
        // Long-lived hosts (the app, `codexbar serve`) keep the warm `agy`
        // session between fetches; only one-shot CLI invocations reset it.
        context.runtime == .cli && !context.persistsCLISessions
    }

    /// Waits for real API readiness, not just socket readiness. Fresh ``agy``
    /// processes bind ports quickly, but ``GetUserStatus`` can return transient
    /// initialization failures for a few seconds after the port appears.
    static func waitForSnapshot(
        pid: pid_t,
        deadline: Date,
        expectedAccountEmail: String? = nil,
        dependencies: SnapshotWaitDependencies) async throws -> AntigravityStatusSnapshot
    {
        var lastFetchError: Error?
        while dependencies.now() < deadline {
            try await Self.checkAuthenticationPrompt(dependencies)
            let remaining = deadline.timeIntervalSince(dependencies.now())
            let portProbeTimeout = min(2.0, max(0.2, remaining))
            let ports: [Int]
            do {
                ports = try await dependencies.listeningPorts(Int(pid), portProbeTimeout)
            } catch {
                guard Self.isNoListeningPortsError(error) else {
                    try await Self.checkAuthenticationPrompt(dependencies)
                    throw error
                }
                ports = []
            }
            if !ports.isEmpty {
                var readySnapshot: AntigravityStatusSnapshot?
                do {
                    let snapshot = try await dependencies.fetchSnapshot(ports)
                    _ = try snapshot.toUsageSnapshot()
                    readySnapshot = snapshot
                } catch {
                    try await Self.checkAuthenticationPrompt(dependencies)
                    lastFetchError = error
                    Self.log.debug("Antigravity CLI HTTPS endpoint not ready", metadata: [
                        "pid": "\(pid)",
                        "ports": ports.map(String.init).joined(separator: ","),
                        "error": error.localizedDescription,
                    ])
                }
                if let readySnapshot {
                    try await Self.checkAuthenticationPrompt(dependencies)
                    if AntigravitySelectedAccountGuard.matches(
                        snapshotAccountEmail: readySnapshot.accountEmail,
                        expectedAccountEmail: expectedAccountEmail)
                    {
                        return readySnapshot
                    }
                    // Fresh `agy` processes can answer quota endpoints before the
                    // signed-in account email is available; keep polling so the
                    // account guard does not reject the cold-start snapshot.
                    lastFetchError = AntigravityStatusProbeError.accountMismatch(
                        expected: expectedAccountEmail,
                        found: readySnapshot.accountEmail)
                    Self.log.debug(
                        "Antigravity CLI HTTPS snapshot account not ready yet",
                        metadata: [
                            "pid": "\(pid)",
                            "ports": ports.map(String.init).joined(separator: ","),
                        ])
                }
            }

            let remainingNanoseconds = UInt64(
                max(0, deadline.timeIntervalSince(dependencies.now())) * 1_000_000_000)
            guard remainingNanoseconds > 0 else { break }
            let sleepNanoseconds = min(dependencies.pollIntervalNanoseconds, remainingNanoseconds)
            if sleepNanoseconds > 0 {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }

        try await Self.checkAuthenticationPrompt(dependencies)
        if let lastFetchError {
            throw lastFetchError
        }
        Self.log.warning("Antigravity CLI HTTPS: no ports found for pid \(pid)")
        throw AntigravityStatusProbeError.portDetectionFailed(
            "Antigravity CLI started but no listening ports found")
    }

    static func containsAuthenticationPrompt(_ output: Data) -> Bool {
        AntigravityCLIAuthenticationPrompt.contains(output)
    }

    private static func checkAuthenticationPrompt(_ dependencies: SnapshotWaitDependencies) async throws {
        let terminalOutput = await dependencies.drainOutput()
        if Self.containsAuthenticationPrompt(terminalOutput) {
            throw AntigravityStatusProbeError.authenticationRequired
        }
    }

    private static func isNoListeningPortsError(_ error: Error) -> Bool {
        if case let AntigravityStatusProbeError.portDetectionFailed(message) = error {
            return message == "no listening ports found"
        }
        if case let SubprocessRunnerError.nonZeroExit(code, stderr) = error {
            return code == 1 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto || context.sourceMode == .cli
    }
}

struct AntigravityOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    static func usageSnapshot(
        from snapshot: AntigravityStatusSnapshot,
        updatedAt: Date = Date()) throws -> UsageSnapshot
    {
        if snapshot.modelQuotas.isEmpty {
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .antigravity,
                    accountEmail: snapshot.accountEmail,
                    accountOrganization: nil,
                    loginMethod: snapshot.accountPlan))
        }
        return try snapshot.toUsageSnapshot()
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = AntigravityRemoteUsageFetcher(
            environment: context.env,
            credentialsUpdateHandler: { credentials in
                guard let accountID = context.selectedTokenAccountID,
                      let updater = context.tokenAccountTokenUpdater
                else {
                    return
                }
                let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
                await updater(.antigravity, accountID, token)
            })
        let snapshot = try await fetcher.fetch()
        let usage = try Self.usageSnapshot(from: snapshot)
        return self.makeResult(
            usage: usage,
            sourceLabel: "oauth")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        let homeURL = context.env["HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return AntigravityOfflineStore.hasOfflineData(home: homeURL, env: context.env)
    }
}

/// Offline fallback (tokscale lesson): when live probes and OAuth have no data,
/// surface the local Antigravity CLI conversation count from
/// `~/.gemini/antigravity-cli/conversations/*.db` as a non-quota snapshot.
/// This keeps the menu bar from going blank on a fresh install without a running
/// server and mirrors tokscale's direct SQLite read (no RPC, no `antigravity sync`).
struct AntigravityOfflineFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.offline"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Cheap file existence check; no SQLite open.
        let homeURL = context.env["HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return AntigravityOfflineStore.hasOfflineData(home: homeURL, env: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let homeURL = context.env["HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let count = AntigravityOfflineStore.countConversations(home: homeURL, env: context.env)
        guard count > 0 else {
            throw AntigravityStatusProbeError.notRunning
        }
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        let offlineWindow = NamedRateWindow(
            id: "antigravity-offline-conversations",
            title: "Offline · \(count) conversation" + (count == 1 ? "" : "s"),
            window: window,
            usageKnown: false)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [offlineWindow],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "offline"))
        return self.makeResult(usage: snapshot, sourceLabel: "offline")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        // Offline is terminal; no further fallback.
        false
    }
}

/// Guards ambient Antigravity snapshots against the explicitly selected account.
///
/// The local desktop probe and the ``agy`` CLI HTTPS server report whichever
/// Antigravity account is signed into the local session. When the user has
/// selected a specific saved Google account, an ambient probe can return a
/// *different* account's quota. Only the OAuth strategy is account-scoped (it
/// fetches with the selected account's injected credentials), so in ``auto``
/// mode we reject a snapshot whose identity does not match the selected account
/// and let the pipeline fall through to OAuth. Explicit ``cli``/``oauth`` source
/// modes stay authoritative and are never second-guessed here.
enum AntigravitySelectedAccountGuard {
    static func matches(snapshotAccountEmail: String?, expectedAccountEmail: String?) -> Bool {
        guard let expected = self.normalizedEmail(expectedAccountEmail) else { return true }
        guard let found = self.normalizedEmail(snapshotAccountEmail) else { return false }
        return found.caseInsensitiveCompare(expected) == .orderedSame
    }

    static func validate(_ usage: UsageSnapshot, context: ProviderFetchContext) throws {
        guard context.sourceMode == .auto, context.selectedTokenAccountID != nil else { return }
        let expected = self.selectedAccountEmail(context: context)
        let found = self.normalizedEmail(usage.identity?.accountEmail)
        guard let expected, let found, found.caseInsensitiveCompare(expected) == .orderedSame else {
            throw AntigravityStatusProbeError.accountMismatch(expected: expected, found: found)
        }
    }

    /// Email of the selected token account, read from the same injected
    /// credentials the OAuth strategy would use (`ANTIGRAVITY_OAUTH_CREDENTIALS_JSON`).
    static func selectedAccountEmail(context: ProviderFetchContext) -> String? {
        guard let value = context.env[AntigravityOAuthCredentialsStore.environmentCredentialsKey],
              let credentials = AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: value)
        else {
            return nil
        }
        return credentials.resolvedAccountEmail
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
