import CodexBarCore
import Foundation
import SweetCookieKit

private struct ClaudeOAuthDebugProbe: Sendable {
    let isAvailable: Bool
    let hasCredentials: Bool
    let ownerRawValue: String
    let sourceRawValue: String
    let isExpired: Bool
    let errorRawValue: String
}

private func probeClaudeOAuthForDebug(
    shouldProbe: Bool,
    environment: [String: String]) async -> ClaudeOAuthDebugProbe
{
    guard shouldProbe else {
        return ClaudeOAuthDebugProbe(
            isAvailable: false,
            hasCredentials: false,
            ownerRawValue: "none",
            sourceRawValue: "none",
            isExpired: false,
            errorRawValue: "not-probed")
    }

    return await withTaskGroup(of: ClaudeOAuthDebugProbe.self) { group in
        group.addTask(priority: .utility) {
            do {
                let record = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: environment,
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true,
                    allowClaudeKeychainRepairWithoutPrompt: false,
                    clearInvalidCache: false)
                return ClaudeOAuthDebugProbe(
                    isAvailable: true,
                    hasCredentials: record.credentials.scopes.contains("user:profile"),
                    ownerRawValue: record.owner.rawValue,
                    sourceRawValue: record.source.rawValue,
                    isExpired: record.credentials.isExpired,
                    errorRawValue: "none")
            } catch let error as ClaudeOAuthCredentialsError {
                let classification = claudeOAuthDebugErrorClassification(error)
                return ClaudeOAuthDebugProbe(
                    isAvailable: classification.isAvailable,
                    hasCredentials: false,
                    ownerRawValue: "none",
                    sourceRawValue: "none",
                    isExpired: false,
                    errorRawValue: classification.label)
            } catch {
                return ClaudeOAuthDebugProbe(
                    isAvailable: true,
                    hasCredentials: false,
                    ownerRawValue: "none",
                    sourceRawValue: "none",
                    isExpired: false,
                    errorRawValue: "other")
            }
        }
        return await group.next() ?? ClaudeOAuthDebugProbe(
            isAvailable: true,
            hasCredentials: false,
            ownerRawValue: "none",
            sourceRawValue: "none",
            isExpired: false,
            errorRawValue: "probe-unavailable")
    }
}

private func claudeOAuthDebugErrorClassification(
    _ error: ClaudeOAuthCredentialsError) -> (isAvailable: Bool, label: String)
{
    switch error {
    case .decodeFailed: (true, "decodeFailed")
    case .missingOAuth: (true, "missingOAuth")
    case .mcpOAuthOnlyKeychain: (true, "mcpOAuthOnlyKeychain")
    case .missingAccessToken: (true, "missingAccessToken")
    case .notFound: (false, "notFound")
    case .keychainError: (true, "keychainError")
    case .readFailed: (true, "readFailed")
    case .refreshFailed: (true, "refreshFailed")
    case .noRefreshToken: (true, "noRefreshToken")
    case .refreshDelegatedToClaudeCLI: (true, "refreshDelegatedToClaudeCLI")
    }
}

@MainActor
extension UsageStore {
    func debugClaudeDump() async -> String {
        await ClaudeStatusProbe.latestDumps()
    }
}

extension UsageStore {
    struct ClaudeDebugLogConfiguration {
        let runtime: CodexBarCore.ProviderRuntime
        let sourceMode: ProviderSourceMode
        let environment: [String: String]
        let webExtrasEnabled: Bool
        let usageDataSource: ClaudeUsageDataSource
        let cookieSource: ProviderCookieSource
        let cookieHeader: String
        let keepCLISessionsAlive: Bool
    }

    static func debugClaudeLog(
        browserDetection: BrowserDetection,
        configuration: ClaudeDebugLogConfiguration) async -> String
    {
        await runWithTimeout(seconds: 15) {
            var lines: [String] = []
            let manualHeader = configuration.cookieSource == .manual
                ? CookieHeaderNormalizer.normalize(configuration.cookieHeader)
                : nil
            let hasKey = if configuration.cookieSource == .off {
                false
            } else if let manualHeader {
                ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: manualHeader)
            } else {
                ClaudeWebAPIFetcher.hasSessionKey(browserDetection: browserDetection) { msg in lines.append(msg) }
            }
            let shouldProbeOAuth = configuration.usageDataSource == .oauth
            let oauthProbe = await probeClaudeOAuthForDebug(
                shouldProbe: shouldProbeOAuth,
                environment: configuration.environment)
            // App Auto always performs one real OAuth attempt. Diagnostics must not preflight that
            // credential path and accidentally mutate the state the fetch will observe.
            let hasOAuthCredentials = (configuration.runtime == .app && configuration.usageDataSource == .auto)
                || (shouldProbeOAuth && oauthProbe.isAvailable)
            let hasClaudeBinary = ClaudeCLIResolver.isAvailable(environment: configuration.environment)
            let delegatedCooldownSeconds = ClaudeOAuthDelegatedRefreshCoordinator.cooldownRemainingSeconds()
            let planningInput = ClaudeSourcePlanningInput(
                runtime: configuration.runtime,
                selectedDataSource: configuration.usageDataSource,
                webExtrasEnabled: configuration.webExtrasEnabled,
                hasWebSession: hasKey,
                hasCLI: hasClaudeBinary,
                hasOAuthCredentials: hasOAuthCredentials)
            let plan = ClaudeSourcePlanner.resolve(input: planningInput)
            let strategy = plan.compatibilityStrategy

            lines.append(contentsOf: plan.debugLines())
            lines.append("hasSessionKey=\(hasKey)")
            lines.append("hasOAuthCredentials=\(hasOAuthCredentials)")
            lines.append("oauthCredentialOwner=\(oauthProbe.ownerRawValue)")
            lines.append("oauthCredentialSource=\(oauthProbe.sourceRawValue)")
            lines.append("oauthCredentialExpired=\(oauthProbe.isExpired)")
            lines.append("oauthCredentialError=\(oauthProbe.errorRawValue)")
            lines.append("delegatedRefreshCLIAvailable=\(hasClaudeBinary)")
            lines.append("delegatedRefreshCooldownActive=\(delegatedCooldownSeconds != nil)")
            if let delegatedCooldownSeconds {
                lines.append("delegatedRefreshCooldownSeconds=\(delegatedCooldownSeconds)")
            }
            lines.append("hasClaudeBinary=\(hasClaudeBinary)")
            if strategy?.useWebExtras == true {
                lines.append("web_extras=enabled")
            }
            lines.append("")

            guard let strategy else {
                lines.append("No planner-selected Claude source.")
                return lines.joined(separator: "\n")
            }

            switch strategy.dataSource {
            case .auto:
                lines.append("Auto source selected.")
                return lines.joined(separator: "\n")
            case .api:
                let hasAdminKey = ProviderTokenResolver.claudeAdminAPIToken(
                    environment: configuration.environment) != nil
                lines.append("Admin API source selected.")
                lines.append("hasAdminAPIKey=\(hasAdminKey)")
                return lines.joined(separator: "\n")
            case .web:
                do {
                    let web: ClaudeWebAPIFetcher.WebUsageData =
                        if let manualHeader {
                            try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: manualHeader) { msg in
                                lines.append(msg)
                            }
                        } else {
                            try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: browserDetection) { msg in
                                lines.append(msg)
                            }
                        }
                    lines.append("")
                    lines.append("Web API summary:")

                    let sessionReset = web.sessionResetsAt?.description ?? "nil"
                    lines.append("session_used=\(web.sessionPercentUsed)% resetsAt=\(sessionReset)")

                    if let weekly = web.weeklyPercentUsed {
                        let weeklyReset = web.weeklyResetsAt?.description ?? "nil"
                        lines.append("weekly_used=\(weekly)% resetsAt=\(weeklyReset)")
                    } else {
                        lines.append("weekly_used=nil")
                    }

                    lines.append("opus_used=\(web.opusPercentUsed?.description ?? "nil")")

                    if let extra = web.extraUsageCost {
                        let resetsAt = extra.resetsAt?.description ?? "nil"
                        let period = extra.period ?? "nil"
                        let line =
                            "extra_usage used=\(extra.used) limit=\(extra.limit) " +
                            "currency=\(extra.currencyCode) period=\(period) resetsAt=\(resetsAt)"
                        lines.append(line)
                    } else {
                        lines.append("extra_usage=nil")
                    }

                    return lines.joined(separator: "\n")
                } catch {
                    lines.append("Web API failed: \(error.localizedDescription)")
                    return lines.joined(separator: "\n")
                }
            case .cli:
                let fetcher = ClaudeUsageFetcher(
                    browserDetection: browserDetection,
                    environment: configuration.environment,
                    runtime: configuration.runtime,
                    dataSource: strategy.dataSource,
                    keepCLISessionsAlive: configuration.keepCLISessionsAlive)
                let cli = await fetcher.debugRawProbe(model: "sonnet")
                lines.append(cli)
                return lines.joined(separator: "\n")
            case .oauth:
                lines.append("OAuth source selected.")
                return lines.joined(separator: "\n")
            }
        }
    }
}
