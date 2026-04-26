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

        let options = OpenAIWebOptions(
            timeout: context.webTimeout,
            debugDumpHTML: context.webDebugDumpHTML,
            verbose: context.verbose)
        let result = try await Self.fetchOpenAIWebCodex(
            context: context,
            options: options,
            browserDetection: context.browserDetection)
        return self.makeResult(
            usage: result.usage,
            credits: result.credits,
            dashboard: result.dashboard,
            sourceLabel: "openai-web")
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        _ = error
        return context.sourceMode == .auto
    }

    private static func managedAccountStoreIsUnreadable(_ context: ProviderFetchContext) -> Bool {
        context.settings?.codex?.managedAccountStoreUnreadable == true
    }

    private static func managedAccountTargetIsUnavailable(_ context: ProviderFetchContext) -> Bool {
        context.settings?.codex?.managedAccountTargetUnavailable == true
    }
}

struct OpenAIWebCodexResult {
    let usage: UsageSnapshot
    let credits: CreditsSnapshot?
    let dashboard: OpenAIDashboardSnapshot
}

enum OpenAIWebCodexError: LocalizedError, Equatable {
    case missingUsage
    case policyRejected(CodexDashboardAuthorityDecision)

    var errorDescription: String? {
        switch self {
        case .missingUsage:
            return "OpenAI web dashboard did not include usage limits."
        case let .policyRejected(decision):
            switch decision.reason {
            case let .wrongEmail(expected, actual):
                var details: [String] = []
                if let expected {
                    details.append("expected \(expected)")
                }
                if let actual {
                    details.append("got \(actual)")
                }
                if details.isEmpty {
                    return "OpenAI web dashboard belonged to the wrong account."
                }
                return "OpenAI web dashboard belonged to the wrong account (\(details.joined(separator: ", ")))."
            case .unresolvedWithoutTrustedEvidence:
                return "Active Codex identity is unresolved and no trusted auth-backed continuity exists."
            case .providerAccountMissingScopedEmail:
                return "Active Codex provider account is missing its scoped email, " +
                    "so dashboard ownership cannot be proven."
            case .providerAccountLacksExactOwnershipProof:
                return "OpenAI web dashboard could not be proven to belong to the active provider account."
            case .missingDashboardSignedInEmail:
                return "OpenAI web dashboard did not expose a signed-in email."
            case let .sameEmailAmbiguity(email):
                return "OpenAI web dashboard email \(email) is ambiguous across multiple known owners."
            default:
                return "OpenAI web dashboard was rejected by Codex dashboard authority."
            }
        }
    }
}

private struct OpenAIWebOptions {
    let timeout: TimeInterval
    let debugDumpHTML: Bool
    let verbose: Bool
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
    @MainActor
    fileprivate static func fetchOpenAIWebCodex(
        context: ProviderFetchContext,
        options: OpenAIWebOptions,
        browserDetection: BrowserDetection) async throws -> OpenAIWebCodexResult
    {
        let logger = WebLogBuffer(verbose: options.verbose)
        let log: @MainActor (String) -> Void = { line in
            logger.append(line)
        }
        do {
            let result = try await Self.fetchOpenAIWebDashboard(
                context: context,
                options: options,
                browserDetection: browserDetection,
                preferCachedCookieHeader: true,
                logger: log)
            return try Self.makeAuthorizedDashboardResult(
                dashboard: result.dashboard,
                context: context,
                routingTargetEmail: result.routingTargetEmail)
        } catch {
            guard Self.shouldRetryWithFreshBrowserImport(after: error) else {
                throw error
            }
            log("Retrying OpenAI web dashboard with a fresh browser cookie import.")
            let result = try await Self.fetchOpenAIWebDashboard(
                context: context,
                options: options,
                browserDetection: browserDetection,
                preferCachedCookieHeader: false,
                logger: log)
            return try Self.makeAuthorizedDashboardResult(
                dashboard: result.dashboard,
                context: context,
                routingTargetEmail: result.routingTargetEmail)
        }
    }

    nonisolated static func shouldRetryWithFreshBrowserImport(after error: Error) -> Bool {
        if error is OpenAIWebCodexError {
            return error as? OpenAIWebCodexError == .missingUsage
        }
        if case OpenAIDashboardFetcher.FetchError.noDashboardData = error {
            return true
        }
        return false
    }

    @MainActor
    static func makeAuthorizedDashboardResultForTesting(
        dashboard: OpenAIDashboardSnapshot,
        context: ProviderFetchContext,
        routingTargetEmail: String?)
        throws -> OpenAIWebCodexResult
    {
        try self.makeAuthorizedDashboardResult(
            dashboard: dashboard,
            context: context,
            routingTargetEmail: routingTargetEmail)
    }

    @MainActor
    private static func makeAuthorizedDashboardResult(
        dashboard: OpenAIDashboardSnapshot,
        context: ProviderFetchContext,
        routingTargetEmail: String?) throws -> OpenAIWebCodexResult
    {
        let input = CodexCLIDashboardAuthorityContext.makeLiveWebInput(
            dashboard: dashboard,
            context: context,
            routingTargetEmail: routingTargetEmail)
        let decision = CodexDashboardAuthority.evaluate(input)

        switch decision.disposition {
        case .attach:
            let attachedAccountEmail = CodexCLIDashboardAuthorityContext.attachmentEmail(from: input)
            guard let usage = dashboard.toUsageSnapshot(provider: .codex, accountEmail: attachedAccountEmail) else {
                throw OpenAIWebCodexError.missingUsage
            }
            let credits = dashboard.toCreditsSnapshot()
            if let attachedAccountEmail {
                OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                    accountEmail: attachedAccountEmail,
                    snapshot: dashboard))
            }
            return OpenAIWebCodexResult(usage: usage, credits: credits, dashboard: dashboard)
        case .displayOnly:
            if decision.cleanup.contains(.dashboardCache) {
                OpenAIDashboardCacheStore.clear()
            }
            throw CodexDashboardPolicyError.displayOnly(decision)
        case .failClosed:
            if decision.cleanup.contains(.dashboardCache) {
                OpenAIDashboardCacheStore.clear()
            }
            throw OpenAIWebCodexError.policyRejected(decision)
        }
    }

    private struct OpenAIWebDashboardFetchResult {
        let dashboard: OpenAIDashboardSnapshot
        let routingTargetEmail: String?
    }

    @MainActor
    private static func fetchOpenAIWebDashboard(
        context: ProviderFetchContext,
        options: OpenAIWebOptions,
        browserDetection: BrowserDetection,
        preferCachedCookieHeader: Bool,
        logger: @MainActor @escaping (String) -> Void) async throws -> OpenAIWebDashboardFetchResult
    {
        let auth = context.fetcher.loadAuthBackedCodexAccount()
        let routingTargetEmail = auth.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowAnyAccount = routingTargetEmail == nil

        let importResult = try await OpenAIDashboardBrowserCookieImporter(browserDetection: browserDetection)
            .importBestCookies(
                intoAccountEmail: routingTargetEmail,
                allowAnyAccount: allowAnyAccount,
                preferCachedCookieHeader: preferCachedCookieHeader,
                logger: logger)
        let effectiveEmail = routingTargetEmail ?? importResult.signedInEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let dashboard = try await OpenAIDashboardFetcher().loadLatestDashboard(
            accountEmail: effectiveEmail,
            logger: logger,
            debugDumpHTML: options.debugDumpHTML,
            timeout: options.timeout)
        return OpenAIWebDashboardFetchResult(
            dashboard: dashboard,
            routingTargetEmail: routingTargetEmail)
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
