#if os(macOS)
import AppKit
import Foundation

public struct CodexWebDashboardStrategy: ProviderFetchStrategy {
    public let id: String = "codex.web.dashboard"
    public let kind: ProviderFetchKind = .webDashboard

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode.usesWeb &&
            !Self.managedAccountStoreIsUnreadable(context) &&
            !Self.managedAccountTargetIsUnavailable(context)
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard !Self.managedAccountStoreIsUnreadable(context) else {
            // A fail-closed placeholder CODEX_HOME does not identify a target account. If the managed store
            // itself is unreadable, web import must not fall back to "any signed-in browser account".
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }
        guard !Self.managedAccountTargetIsUnavailable(context) else {
            // If the selected managed account no longer exists in a readable store, web import must not
            // fall back to "any signed-in browser account" for that stale selection.
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }

        // Ensure AppKit is initialized before using WebKit in a CLI.
        await MainActor.run {
            _ = NSApplication.shared
        }

        let baseAccountInfo = context.fetcher.loadAccountInfo()
        let accountInfo = await Self.resolveAuthoritativeAccountInfo(
            baseAccountInfo,
            env: context.env)
        let accountEmail = accountInfo.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceAccountID = accountInfo.workspaceAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let workspaceLabel = accountInfo.workspaceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = OpenAIWebOptions(
            timeout: context.webTimeout,
            debugDumpHTML: context.webDebugDumpHTML,
            verbose: context.verbose)
        let result = try await Self.fetchOpenAIWebCodex(
            OpenAIWebFetchRequest(
                accountEmail: accountEmail,
                workspaceAccountID: workspaceAccountID,
                workspaceLabel: workspaceLabel,
                fetcher: context.fetcher,
                options: options,
                browserDetection: context.browserDetection))
        return self.makeResult(
            usage: result.usage,
            credits: result.credits,
            dashboard: result.dashboard,
            sourceLabel: "openai-web")
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        _ = error
        return true
    }

    private static func managedAccountStoreIsUnreadable(_ context: ProviderFetchContext) -> Bool {
        context.settings?.codex?.managedAccountStoreUnreadable == true
    }

    private static func managedAccountTargetIsUnavailable(_ context: ProviderFetchContext) -> Bool {
        context.settings?.codex?.managedAccountTargetUnavailable == true
    }
}

private struct OpenAIWebCodexResult {
    let usage: UsageSnapshot
    let credits: CreditsSnapshot?
    let dashboard: OpenAIDashboardSnapshot
}

private enum OpenAIWebCodexError: LocalizedError {
    case missingUsage

    var errorDescription: String? {
        switch self {
        case .missingUsage:
            "OpenAI web dashboard did not include usage limits."
        }
    }
}

private struct OpenAIWebOptions {
    let timeout: TimeInterval
    let debugDumpHTML: Bool
    let verbose: Bool
}

private struct OpenAIWebFetchRequest {
    let accountEmail: String?
    let workspaceAccountID: String?
    let workspaceLabel: String?
    let fetcher: UsageFetcher
    let options: OpenAIWebOptions
    let browserDetection: BrowserDetection
}

@MainActor
private final class WebLogBuffer {
    private var lines: [String] = []
    private let maxCount: Int
    private let verbose: Bool
    private let logger = CodexBarLog.logger(LogCategories.openAIWeb)

    init(maxCount: Int = 300, verbose: Bool) {
        self.maxCount = maxCount
        self.verbose = verbose
    }

    func append(_ line: String) {
        self.lines.append(line)
        if self.lines.count > self.maxCount {
            self.lines.removeFirst(self.lines.count - self.maxCount)
        }
        if self.verbose {
            self.logger.verbose(line)
        }
    }

    func snapshot() -> [String] {
        self.lines
    }
}

extension CodexWebDashboardStrategy {
    private static func resolveAuthoritativeAccountInfo(
        _ accountInfo: AccountInfo,
        env: [String: String]) async -> AccountInfo
    {
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: env),
              credentials.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return accountInfo
        }

        do {
            let authoritativeIdentity = try await CodexOpenAIWorkspaceResolver.resolve(credentials: credentials)
            if let authoritativeIdentity {
                try? CodexOpenAIWorkspaceIdentityCache().store(authoritativeIdentity)
                return CodexOpenAIWorkspaceResolver.mergeAuthoritativeIdentity(
                    into: accountInfo,
                    authoritativeIdentity: authoritativeIdentity)
            }
        } catch {
            // Keep the weaker fallback when the authoritative lookup is unavailable at runtime.
        }

        if let cachedWorkspaceLabel = CodexOpenAIWorkspaceIdentityCache().workspaceLabel(for: credentials.accountId) {
            return AccountInfo(
                email: accountInfo.email,
                plan: accountInfo.plan,
                workspaceLabel: cachedWorkspaceLabel,
                workspaceAccountID: credentials.accountId)
        }

        return accountInfo
    }

    @MainActor
    fileprivate static func fetchOpenAIWebCodex(
        _ request: OpenAIWebFetchRequest) async throws -> OpenAIWebCodexResult
    {
        let logger = WebLogBuffer(verbose: request.options.verbose)
        let log: @MainActor (String) -> Void = { line in
            logger.append(line)
        }
        let dashboard = try await Self.fetchOpenAIWebDashboard(request, logger: log)
        guard let usage = dashboard.toUsageSnapshot(
            provider: .codex,
            accountEmail: request.accountEmail,
            accountOrganization: request.workspaceLabel,
            accountWorkspaceID: request.workspaceAccountID)
        else {
            throw OpenAIWebCodexError.missingUsage
        }
        let credits = dashboard.toCreditsSnapshot()
        return OpenAIWebCodexResult(usage: usage, credits: credits, dashboard: dashboard)
    }

    @MainActor
    fileprivate static func fetchOpenAIWebDashboard(
        _ request: OpenAIWebFetchRequest,
        logger: @MainActor @escaping (String) -> Void) async throws -> OpenAIDashboardSnapshot
    {
        let trimmed = request.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = request.fetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexEmail = trimmed?.isEmpty == false ? trimmed : (fallback?.isEmpty == false ? fallback : nil)
        let allowAnyAccount = codexEmail == nil

        let importResult = try await OpenAIDashboardBrowserCookieImporter(browserDetection: request.browserDetection)
            .importBestCookies(
                intoAccountEmail: codexEmail,
                intoWorkspaceAccountID: request.workspaceAccountID,
                intoWorkspaceLabel: request.workspaceLabel,
                allowAnyAccount: allowAnyAccount,
                logger: logger)
        let effectiveEmail = codexEmail ?? importResult.signedInEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
            accountEmail: effectiveEmail,
            workspaceAccountID: request.workspaceAccountID,
            workspaceLabel: request.workspaceLabel,
            logger: logger,
            debugDumpHTML: request.options.debugDumpHTML,
            timeout: request.options.timeout)
        let cacheEmail = effectiveEmail ?? dash.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cacheEmail, !cacheEmail.isEmpty {
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: cacheEmail, snapshot: dash))
        }
        return dash
    }
}
#else
public struct CodexWebDashboardStrategy: ProviderFetchStrategy {
    public let id: String = "codex.web.dashboard"
    public let kind: ProviderFetchKind = .webDashboard

    public init() {}

    public func isAvailable(_: ProviderFetchContext) async -> Bool {
        false
    }

    public func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw ProviderFetchError.noAvailableStrategy(.codex)
    }

    public func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
#endif
