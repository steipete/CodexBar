import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: MuseSettingsReader.apiKeyEnvironmentKeys[0],
        precedence: .environment,
        environmentHasValue: { MuseSettingsReader.apiKey(environment: $0) != nil },
        resolve: MuseSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Muse API keys (META_API_KEY).",
            placeholder: "Paste META_API_KEY…",
            injection: .environment(key: MuseSettingsReader.apiKeyEnvironmentKeys[0]),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in MuseUsageError.missingCredentials.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse",
                shortDisplayName: "Muse",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Muse usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free",
                    "pro": "Pro",
                    "team": "Team",
                    "enterprise": "Enterprise",
                ],
                dashboardURL: "https://dev.meta.ai",
                subscriptionDashboardURL: "https://accountscenter.meta.com/muse_code/",
                changelogURL: "https://github.com/meta/muse-code/releases",
                statusPageURL: nil,
                statusLinkURL: "https://developers.facebook.com/status/"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 6 / 255, green: 104 / 255, blue: 225 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0668E1),
                    ProviderColor(hex: 0x00AEFF),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                burnDownWidgetColor: ProviderColor(red: 6 / 255, green: 104 / 255, blue: 225 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Muse cost summary is not yet available. Set META_API_KEY or run `muse login`." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["muse-code"],
                binaryLocator: { BinaryLocator.resolveMuseBinary() },
                versionDetector: { _ in Self.detectVersion() },
                supportsCostCommand: false))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api, .cli],
            pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        // CLI strategy is fallback when no API key is present but CLI is installed.
        let hasKey = MuseSettingsReader.apiKey(environment: context.env) != nil
        let hasCLI = BinaryLocator.resolveMuseBinary() != nil

        switch context.sourceMode {
        case .api:
            return [MuseAPIFetchStrategy()]
        case .cli:
            return hasCLI ? [MuseCLIFetchStrategy()] : []
        case .auto:
            if hasKey {
                return [MuseAPIFetchStrategy()]
            }
            if hasCLI {
                return [MuseCLIFetchStrategy()]
            }
            // Keep strategy available so missing-credentials surfaces as friendly error.
            return [MuseAPIFetchStrategy()]
        case .web, .oauth:
            return []
        }
    }

    private static func detectVersion() -> String? {
        guard let binary = BinaryLocator.resolveMuseBinary() else { return nil }
        let result = ShellCommand.run(binary, args: ["--version"], timeoutSeconds: 5)
        guard result.exitCode == 0 else { return nil }
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}

struct MuseAPIFetchStrategy: ProviderFetchStrategy {
    let id = "muse.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Always available so missing-credentials error is user-friendly.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = MuseSettingsReader.apiKey(environment: context.env) else {
            throw MuseUsageError.missingCredentials
        }
        let baseURL = MuseSettingsReader.baseURL(environment: context.env)
        let snapshot = try await MuseUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: baseURL,
            transport: self.transport)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct MuseCLIFetchStrategy: ProviderFetchStrategy {
    let id = "muse.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveMuseBinary() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let binary = BinaryLocator.resolveMuseBinary() else {
            throw MuseUsageError.missingCredentials
        }
        // Check that CLI is authenticated — `muse login` stores in Keychain.
        // We do not parse quota from CLI yet; return identity-only snapshot
        // that proves CLI is installed and reachable.
        let versionResult = ShellCommand.run(binary, args: ["--version"], timeoutSeconds: 5)
        let version = (versionResult.stdout + versionResult.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let loginCheck = ShellCommand.run(binary, args: ["auth", "--help"], timeoutSeconds: 5)
        let isAuthenticated = loginCheck.exitCode == 0

        let snapshot = MuseUsageSnapshot(
            primary: nil,
            secondary: nil,
            accountEmail: nil,
            plan: isAuthenticated ? "Muse CLI (\(version))" : "CLI (not logged in)",
            updatedAt: Date())

        if !isAuthenticated, MuseSettingsReader.apiKey(environment: context.env) == nil {
            throw MuseUsageError.missingCredentials
        }

        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

/// Minimal shell helper local to Muse.
private enum ShellCommand {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func run(_ executable: String, args: [String], timeoutSeconds: Int) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: error.localizedDescription, exitCode: 127)
        }

        let timeout = DispatchTime.now() + .seconds(timeoutSeconds)
        while process.isRunning, DispatchTime.now() < timeout {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return Result(stdout: "", stderr: "timed out", exitCode: 124)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return Result(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus)
    }
}
