import Foundation

public enum DeepSeekProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepseek,
            metadata: ProviderMetadata(
                id: .deepseek,
                displayName: "DeepSeek",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show DeepSeek usage",
                cliName: "deepseek",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.deepSeekCookieImportOrder,
                dashboardURL: "https://platform.deepseek.com/usage",
                statusPageURL: "https://status.deepseek.com",
                statusLinkURL: "https://status.deepseek.com"),
            branding: ProviderBranding(
                iconStyle: .deepseek,
                iconResourceName: "ProviderIcon-deepseek",
                color: ProviderColor(red: 0.32, green: 0.49, blue: 0.94)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "DeepSeek usage summaries need a platform.deepseek.com web session." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "deepseek",
                aliases: ["deep-seek", "ds"],
                versionDetector: nil))
    }

    static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            return [DeepSeekWebOnlyFetchStrategy()]
        case .api:
            return [DeepSeekAPITokenFetchStrategy()]
        case .cli, .oauth:
            return []
        case .auto:
            break
        }
        // Auto: with an API key, the API strategy also enriches web balance; without
        // one, fall back to the web-only strategy so cookies alone still yield balance.
        if ProviderTokenResolver.deepseekToken(environment: context.env) != nil {
            return [DeepSeekAPITokenFetchStrategy(), DeepSeekWebOnlyFetchStrategy()]
        }
        return [DeepSeekWebOnlyFetchStrategy()]
    }
}

struct DeepSeekAPITokenFetchStrategy: ProviderFetchStrategy {
    let id: String = "deepseek.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.deepseekToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.deepseekToken(environment: context.env) else {
            throw DeepSeekUsageError.missingCredentials
        }

        let snapshot = try await DeepSeekUsageFetcher.fetchUsage(
            apiKey: apiKey,
            includeOptionalUsage: false)
        let enriched = try await Self.enrichUsageSnapshot(
            context: context,
            snapshot: snapshot)
        return self.makeResult(usage: enriched.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.settings?.deepseek?.cookieSource != .off else { return false }
        switch error {
        case DeepSeekUsageError.missingCredentials, DeepSeekUsageError.invalidCredentials:
            return true
        case let DeepSeekUsageError.apiError(message):
            return message.contains("401") || message.contains("403")
        default:
            return false
        }
    }
}

extension DeepSeekAPITokenFetchStrategy {
    static func shouldApplyWebBalance(
        apiSnapshot: DeepSeekUsageSnapshot,
        webIdentity: DeepSeekAccountIdentity?) -> Bool
    {
        guard let webEmail = webIdentity?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !webEmail.isEmpty
        else {
            return false
        }
        guard let apiEmail = apiSnapshot.identity?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiEmail.isEmpty
        else {
            return false
        }
        return apiEmail.caseInsensitiveCompare(webEmail) == .orderedSame
    }

    static func enrichUsageSnapshot(
        context: ProviderFetchContext,
        snapshot: DeepSeekUsageSnapshot) async throws -> DeepSeekUsageSnapshot
    {
        guard context.includeOptionalUsage else { return snapshot }
        guard context.settings?.deepseek?.cookieSource != .off else { return snapshot }

        var enriched = snapshot
        var rejectedCredentials = false
        let candidates = DeepSeekWebEnrichmentResolver.candidates(context: context)
        for candidate in candidates {
            guard !candidate.session.isEmpty else { continue }
            do {
                let account = try await DeepSeekUsageFetcher.fetchWebAccount(session: candidate.session)
                let usage = try? await DeepSeekUsageFetcher.fetchUsageSummary(session: candidate.session)
                guard account.summary != nil || usage != nil else { continue }
                let applyWebBalance = Self.shouldApplyWebBalance(
                    apiSnapshot: enriched,
                    webIdentity: account.identity)
                enriched = DeepSeekUsageSnapshot(
                    isAvailable: enriched.isAvailable,
                    currency: applyWebBalance
                        ? (account.summary?.currency ?? enriched.currency)
                        : enriched.currency,
                    totalBalance: applyWebBalance
                        ? (account.summary?.totalBalance ?? enriched.totalBalance)
                        : enriched.totalBalance,
                    grantedBalance: applyWebBalance
                        ? (account.summary?.grantedBalance ?? enriched.grantedBalance)
                        : enriched.grantedBalance,
                    toppedUpBalance: applyWebBalance
                        ? (account.summary?.paidBalance ?? enriched.toppedUpBalance)
                        : enriched.toppedUpBalance,
                    usageSummary: usage,
                    accountSummary: applyWebBalance ? account.summary : enriched.accountSummary,
                    identity: account.identity ?? enriched.identity,
                    updatedAt: enriched.updatedAt)
                DeepSeekWebEnrichmentResolver.cacheValidated(candidate)
                return enriched
            } catch DeepSeekUsageError.invalidCredentials {
                rejectedCredentials = true
                if candidate.isCached {
                    CookieHeaderCache.clear(provider: .deepseek)
                }
                continue
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw error
                }
                continue
            }
        }

        if rejectedCredentials, enriched.usageSummary == nil {
            Self.log.debug("DeepSeek platform session rejected; usage summary omitted.")
        }
        return enriched
    }

    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)
}

/// Produces a DeepSeek usage snapshot from a platform web session alone, without
/// requiring an API key. Balance comes from `get_user_summary`; usage summaries and
/// identity are best-effort enrichment on top.
struct DeepSeekWebOnlyFetchStrategy: ProviderFetchStrategy {
    let id: String = "deepseek.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.deepSeekUsage)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.deepseek?.cookieSource != .off else { return false }
        if DeepSeekWebEnrichmentResolver.hasExplicitOrCachedSession(context: context) {
            return true
        }
        #if os(macOS)
        if DeepSeekWebEnrichmentResolver.allowsBrowserCookieImport(context: context) {
            do {
                return try !DeepSeekCookieImporter.importSessions(
                    browserDetection: context.browserDetection).isEmpty
            } catch {
                // Surface browser permission/setup failures during fetch instead of hiding them.
                return true
            }
        }
        #endif
        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var lastError: Error = DeepSeekUsageError.invalidCredentials
        for candidate in DeepSeekWebEnrichmentResolver.candidates(context: context) {
            guard !candidate.session.isEmpty else { continue }
            do {
                let account = try await DeepSeekUsageFetcher.fetchWebAccount(session: candidate.session)
                guard let summary = account.summary else {
                    throw DeepSeekUsageError.invalidCredentials
                }
                let usage = await context.includeOptionalUsage
                    ? (try? DeepSeekUsageFetcher.fetchUsageSummary(session: candidate.session))
                    : nil
                let snapshot = DeepSeekUsageSnapshot(
                    isAvailable: true,
                    currency: summary.currency,
                    totalBalance: summary.totalBalance,
                    grantedBalance: summary.grantedBalance,
                    toppedUpBalance: summary.paidBalance,
                    usageSummary: usage,
                    accountSummary: summary,
                    identity: account.identity,
                    updatedAt: Date())
                DeepSeekWebEnrichmentResolver.cacheValidated(candidate)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
            } catch DeepSeekUsageError.invalidCredentials {
                lastError = DeepSeekUsageError.invalidCredentials
                if candidate.isCached {
                    CookieHeaderCache.clear(provider: .deepseek)
                }
                continue
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                lastError = error
                continue
            }
        }
        throw lastError
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
