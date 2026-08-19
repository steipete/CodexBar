import Foundation

struct CodexPATFetchStrategy: ProviderFetchStrategy {
    let id: String = "codex.pat"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        (try? CodexOAuthCredentialsStore.loadPAT(env: Self.credentialEnvironment(context.env))) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let credentialEnv = Self.credentialEnvironment(context.env)
        let credentials = try CodexOAuthCredentialsStore.loadPAT(env: credentialEnv)
        let fetched = try await CodexPATUsageFetcher.fetchUsage(
            credentials: credentials,
            cliVersion: Self.resolvedCLIVersion(context: context),
            env: credentialEnv)
        return try Self.makeResult(
            usageResponse: fetched.usage,
            whoami: fetched.whoami,
            updatedAt: Date())
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if let fetchError = error as? CodexOAuthFetchError {
            switch fetchError {
            case .unauthorized:
                return true
            case .invalidResponse, .serverError, .networkError:
                return false
            }
        }
        if let credentialsError = error as? CodexOAuthCredentialsError {
            switch credentialsError {
            case .notFound, .unreadable, .missingTokens:
                return true
            case .decodeFailed, .readOnlySource, .nativeRefreshRequired:
                return false
            }
        }
        return false
    }

    /// PAT lives in the Codex CLI auth file. Managed-account `CODEX_HOME` isolation is for OAuth
    /// workspaces and must not hide that token, including the fail-closed dummy home used when a
    /// persisted managed account no longer exists. Profile homes keep a local PAT when present and
    /// otherwise fall through to ambient `~/.codex`.
    static func credentialEnvironment(_ env: [String: String]) -> [String: String] {
        guard env["CODEX_HOME"] != nil else { return env }
        if let home = env["CODEX_HOME"], self.isManagedOrFailClosedCodexHome(home) {
            return self.ambientCredentialEnvironment(env)
        }
        if (try? CodexOAuthCredentialsStore.loadPAT(env: env)) != nil {
            return env
        }
        return self.ambientCredentialEnvironment(env)
    }

    private static func ambientCredentialEnvironment(_ env: [String: String]) -> [String: String] {
        var ambient = env
        // `loadPAT` only honors `CODEX_HOME`. Stripping a managed home without pointing at
        // `$HOME/.codex` falls through to the process user's real home, which hides a PAT
        // that tests (and some launchd/sudo environments) keep under a different HOME.
        if let home = env["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            ambient["CODEX_HOME"] = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
                .standardizedFileURL.path
        } else {
            ambient.removeValue(forKey: "CODEX_HOME")
        }
        return ambient
    }

    private static func isManagedOrFailClosedCodexHome(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if (normalized as NSString).lastPathComponent == "managed-store-unreadable" {
            return true
        }
        return normalized.split(separator: "/").contains("managed-codex-homes")
    }

    private static func resolvedCLIVersion(context: ProviderFetchContext) -> String? {
        if let version = context.resolvedCLIVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty
        {
            return version
        }
        return CodexProviderDescriptor.descriptor.cli.versionDetector?(context.browserDetection)
    }

    private static func makeResult(
        usageResponse: CodexUsageResponse,
        whoami: CodexPATWhoami?,
        updatedAt: Date) throws -> ProviderFetchResult
    {
        let credits = Self.mapCredits(response: usageResponse, updatedAt: updatedAt)
        let reconciled = CodexReconciledState.fromPAT(
            response: usageResponse,
            whoami: whoami,
            updatedAt: updatedAt)

        if let reconciled {
            let dataConfidence: UsageDataConfidence =
                usageResponse.rateLimit?.hasWindowDecodeFailure == true
                    || usageResponse.additionalRateLimitsDecodeFailed
                    ? .unknown
                    : .exact
            return Self.patResult(
                usage: reconciled.toUsageSnapshot().withDataConfidence(dataConfidence),
                credits: credits)
        }

        guard credits != nil else {
            throw UsageError.noRateLimitsFound
        }

        return Self.patResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: updatedAt,
                identity: CodexReconciledState.patIdentity(response: usageResponse, whoami: whoami)),
            credits: credits)
    }

    private static func mapCredits(
        response: CodexUsageResponse,
        updatedAt: Date) -> CreditsSnapshot?
    {
        let balance = response.credits?.balance
        let creditLimit = response.resolvedIndividualLimit?.codexCreditLimitSnapshot(updatedAt: updatedAt)
        guard balance != nil || creditLimit != nil else { return nil }
        return CreditsSnapshot(
            remaining: balance ?? 0,
            events: [],
            updatedAt: updatedAt,
            codexCreditLimit: creditLimit)
    }

    private static func patResult(usage: UsageSnapshot, credits: CreditsSnapshot?)
        -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: usage,
            credits: credits,
            dashboard: nil,
            sourceLabel: CodexUsageDataSource.pat.sourceLabel,
            strategyID: "codex.pat",
            strategyKind: .apiToken,
            codexResetCreditsAttempted: true)
    }
}

#if DEBUG
extension CodexPATFetchStrategy {
    static func _resolvedCLIVersionForTesting(context: ProviderFetchContext) -> String? {
        self.resolvedCLIVersion(context: context)
    }

    static func _credentialEnvironmentForTesting(_ env: [String: String]) -> [String: String] {
        self.credentialEnvironment(env)
    }

    static func _mapResultForTesting(
        _ data: Data,
        whoami: CodexPATWhoami? = nil) throws -> ProviderFetchResult
    {
        let usageResponse = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return try self.makeResult(
            usageResponse: usageResponse,
            whoami: whoami,
            updatedAt: Date())
    }
}
#endif
