import Foundation

public enum AntigravityProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .antigravity,
            metadata: ProviderMetadata(
                id: .antigravity,
                displayName: "Antigravity",
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
                dashboardURL: nil,
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .antigravity,
                iconResourceName: "ProviderIcon-antigravity",
                color: ProviderColor(red: 96 / 255, green: 186 / 255, blue: 126 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Antigravity cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "antigravity",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let app = AntigravityStatusFetchStrategy(source: .app)
        let cli = AntigravityCLIHTTPSFetchStrategy()
        let ide = AntigravityStatusFetchStrategy(source: .ide)
        let oauth = AntigravityOAuthFetchStrategy()
        switch context.sourceMode {
        case .cli:
            return [app, cli, ide]
        case .oauth:
            return [oauth]
        case .auto:
            if context.selectedTokenAccountID != nil ||
                context.env[AntigravityOAuthCredentialsStore.environmentCredentialsKey] != nil ||
                self.hasSharedOAuthCredentials(context: context)
            {
                return [app, cli, ide, oauth]
            }
            return [app, cli, ide]
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
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

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

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveAntigravityBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let binary = BinaryLocator.resolveAntigravityBinary(env: context.env) else {
            throw AntigravityStatusProbeError.notRunning
        }
        let result = try await self.fetchUsingWarmSession(
            binary: binary,
            idleWindow: context.persistentCLISessionIdleWindow,
            resetAfterFetch: Self.shouldResetSessionAfterFetch(context))
        try AntigravitySelectedAccountGuard.validate(result.usage, context: context)
        return result
    }

    private func fetchUsingWarmSession(
        binary: String,
        idleWindow: TimeInterval?,
        resetAfterFetch: Bool) async throws -> ProviderFetchResult
    {
        let session = AntigravityCLISession.shared
        let pid = try await session.beginProbe(binary: binary, idleWindow: idleWindow)
        let deadline = Date().addingTimeInterval(5.0)
        let snap: AntigravityStatusSnapshot
        let usage: UsageSnapshot
        do {
            snap = try await Self.waitForSnapshot(
                pid: pid,
                deadline: deadline,
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
                    return readySnapshot
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

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
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
