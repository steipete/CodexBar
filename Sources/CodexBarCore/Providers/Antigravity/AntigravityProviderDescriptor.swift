import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AntigravityProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .antigravity,
            metadata: ProviderMetadata(
                id: .antigravity,
                displayName: "Antigravity",
                sessionLabel: "Claude",
                weeklyLabel: "Gemini Pro",
                opusLabel: "Gemini Flash",
                supportsOpus: true,
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
        let local = AntigravityStatusFetchStrategy()
        let cli = AntigravityCLIHTTPSFetchStrategy()
        let oauth = AntigravityOAuthFetchStrategy()
        switch context.sourceMode {
        case .cli:
            return [local, cli]
        case .oauth:
            return [oauth]
        case .auto:
            return [local, cli, oauth]
        case .web, .api:
            return []
        }
    }
}

struct AntigravityStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.local"
    let kind: ProviderFetchKind = .localProbe
    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // IDE-only: `agy` is owned by AntigravityCLIHTTPSFetchStrategy, which
        // waits for real API readiness. Probing a half-warmed `agy` here would
        // burn the timeout on a process that is not yet answering, so the
        // local probe only handles the running-desktop case and otherwise
        // fails over to the CLI strategy.
        let probe = AntigravityStatusProbe(processScope: .ideOnly)
        let snap = try await probe.fetch()
        let usage = try snap.toUsageSnapshot()
        try AntigravitySelectedAccountGuard.validate(usage, context: context)
        return self.makeResult(
            usage: usage,
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto || context.sourceMode == .cli
    }
}

/// When the desktop Antigravity app is closed (no ``language_server`` running),
/// this strategy spawns or reuses ``agy`` and talks to the HTTPS localhost
/// server embedded in that CLI process. ``agy`` is an interactive REPL, not a
/// query command, so CodexBar never scrapes TUI output here; it only keeps the
/// process alive long enough for the server to answer ``GetUserStatus``.
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
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard Self.supportsLocalhostServerTrust else { return false }
        return BinaryLocator.resolveAntigravityBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard Self.supportsLocalhostServerTrust else {
            throw AntigravityStatusProbeError.notRunning
        }
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

    private static var supportsLocalhostServerTrust: Bool {
        #if os(Linux)
        false
        #else
        true
        #endif
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
        while Date() < deadline {
            try await Self.checkAuthenticationPrompt(dependencies)
            let remaining = deadline.timeIntervalSinceNow
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

            let remainingNanoseconds = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
            guard remainingNanoseconds > 0 else { break }
            try await Task.sleep(nanoseconds: min(dependencies.pollIntervalNanoseconds, remainingNanoseconds))
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
        context.sourceMode == .auto
    }
}

struct AntigravityOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
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
        let usage = if snapshot.modelQuotas.isEmpty {
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .antigravity,
                    accountEmail: snapshot.accountEmail,
                    accountOrganization: nil,
                    loginMethod: snapshot.accountPlan))
        } else {
            try snapshot.toUsageSnapshot()
        }
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
