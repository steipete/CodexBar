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
        if context.selectedTokenAccountID != nil {
            return [oauth]
        }
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

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AntigravityStatusProbe()
        let snap = try await probe.fetch()
        let usage = try snap.toUsageSnapshot()
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

    struct SnapshotWaitDependencies: Sendable {
        let pollIntervalNanoseconds: UInt64
        let listeningPorts: @Sendable (Int, TimeInterval) async throws -> [Int]
        let drainOutput: @Sendable () async -> Void
        let fetchSnapshot: @Sendable ([Int]) async throws -> AntigravityStatusSnapshot
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveAntigravityBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let binary = BinaryLocator.resolveAntigravityBinary(env: context.env) else {
            throw AntigravityStatusProbeError.notRunning
        }
        return try await self.fetchUsingWarmSession(
            binary: binary,
            resetAfterFetch: Self.shouldResetSessionAfterFetch(context))
    }

    private func fetchUsingWarmSession(binary: String, resetAfterFetch: Bool) async throws -> ProviderFetchResult {
        let session = AntigravityCLISession.shared
        let pid = try await session.beginProbe(binary: binary)
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
            await session.finishProbe(success: false, resetAfterFetch: resetAfterFetch)
            throw error
        }

        return self.makeResult(
            usage: usage,
            sourceLabel: Self.sourceLabel)
    }

    static func shouldResetSessionAfterFetch(_ context: ProviderFetchContext) -> Bool {
        context.runtime == .cli
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
            await dependencies.drainOutput()
            let remaining = deadline.timeIntervalSinceNow
            let portProbeTimeout = min(2.0, max(0.2, remaining))
            let ports: [Int]
            do {
                ports = try await dependencies.listeningPorts(Int(pid), portProbeTimeout)
            } catch {
                guard Self.isNoListeningPortsError(error) else {
                    throw error
                }
                ports = []
            }
            if !ports.isEmpty {
                do {
                    let snapshot = try await dependencies.fetchSnapshot(ports)
                    _ = try snapshot.toUsageSnapshot()
                    return snapshot
                } catch {
                    lastFetchError = error
                    Self.log.debug("Antigravity CLI HTTPS endpoint not ready", metadata: [
                        "pid": "\(pid)",
                        "ports": ports.map(String.init).joined(separator: ","),
                        "error": error.localizedDescription,
                    ])
                }
            }

            let remainingNanoseconds = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
            guard remainingNanoseconds > 0 else { break }
            try await Task.sleep(nanoseconds: min(dependencies.pollIntervalNanoseconds, remainingNanoseconds))
        }

        if let lastFetchError {
            throw lastFetchError
        }
        Self.log.warning("Antigravity CLI HTTPS: no ports found for pid \(pid)")
        throw AntigravityStatusProbeError.portDetectionFailed(
            "Antigravity CLI started but no listening ports found")
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
