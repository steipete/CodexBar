#if os(macOS)
import AppKit
import Foundation

public struct CodexWebDashboardStrategy: ProviderFetchStrategy {
    public let id: String = "codex.web.dashboard"
    public let kind: ProviderFetchKind = .webDashboard

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode.usesWeb
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Ensure AppKit is initialized before using WebKit in a CLI.
        await MainActor.run {
            _ = NSApplication.shared
        }

        let manualCookieHeader = context.settings?.codex?.manualCookieHeader
        let selectedAccountEmail = context.settings?.codex?.accountEmail?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let workspaceLabel = context.settings?.codex?.workspaceLabel?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let accountEmail: String? = if let selectedAccountEmail, !selectedAccountEmail.isEmpty {
            selectedAccountEmail
        } else if manualCookieHeader == nil {
            context.fetcher.loadAccountInfo().email?
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else {
            nil
        }
        let options = OpenAIWebOptions(
            timeout: context.webTimeout,
            debugDumpHTML: context.webDebugDumpHTML,
            verbose: context.verbose)
        let result = try await Self.fetchOpenAIWebCodex(
            OpenAIWebFetchRequest(
                accountEmail: accountEmail,
                workspaceLabel: workspaceLabel,
                manualCookieHeader: context.settings?.codex?.manualCookieHeader,
                manualMode: context.settings?.codex?.cookieSource == .manual,
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
    let workspaceLabel: String?
    let manualCookieHeader: String?
    let manualMode: Bool
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
            accountOrganization: request.workspaceLabel)
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
        let trimmed = request.accountEmail?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let fallback: String? = if request.manualCookieHeader == nil {
            request.fetcher.loadAccountInfo().email?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } else {
            nil
        }
        let codexEmail = trimmed?.isEmpty == false ? trimmed : (fallback?.isEmpty == false ? fallback : nil)
        let allowAnyAccount = codexEmail == nil

        if let codexEmail, !codexEmail.isEmpty {
            do {
                let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: codexEmail,
                    workspaceLabel: request.workspaceLabel,
                    logger: logger,
                    debugDumpHTML: request.options.debugDumpHTML,
                    timeout: request.options.timeout)
                OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: codexEmail, snapshot: dash))
                return dash
            } catch OpenAIDashboardFetcher.FetchError.loginRequired {
                logger("stored dashboard session for \(codexEmail) requires login; falling back to cookie import")
            } catch {
                logger("stored dashboard session for \(codexEmail) failed: \(error.localizedDescription)")
            }
        }

        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: request.browserDetection)
        let importResult: OpenAIDashboardBrowserCookieImporter.ImportResult
        if let manualCookieHeader = request.manualCookieHeader,
           CookieHeaderNormalizer.normalize(manualCookieHeader) != nil
        {
            importResult = try await importer.importManualCookies(
                cookieHeader: manualCookieHeader,
                intoAccountEmail: codexEmail,
                intoWorkspaceLabel: request.workspaceLabel,
                allowAnyAccount: allowAnyAccount,
                logger: logger)
        } else if request.manualMode {
            throw OpenAIDashboardBrowserCookieImporter.ImportError.manualCookieHeaderInvalid
        } else {
            importResult = try await importer.importBestCookies(
                intoAccountEmail: codexEmail,
                intoWorkspaceLabel: request.workspaceLabel,
                allowAnyAccount: allowAnyAccount,
                logger: logger)
        }
        let effectiveEmail = codexEmail ?? importResult.signedInEmail?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
            accountEmail: effectiveEmail,
            workspaceLabel: request.workspaceLabel,
            logger: logger,
            debugDumpHTML: request.options.debugDumpHTML,
            timeout: request.options.timeout)
        let cacheEmail = effectiveEmail ?? dash.signedInEmail?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
