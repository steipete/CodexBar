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

        let fallbackAccountEmail = context.fetcher.loadAccountInfo().email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let importInput = Self.resolveCookieImportInput(
            settings: context.settings?.codex,
            fallbackAccountEmail: fallbackAccountEmail)
        let options = OpenAIWebOptions(
            timeout: context.webTimeout,
            debugDumpHTML: context.webDebugDumpHTML,
            verbose: context.verbose)
        let result = try await Self.fetchOpenAIWebCodex(
            importInput: importInput,
            fetcher: context.fetcher,
            options: options,
            browserDetection: context.browserDetection)
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

private struct OpenAIWebCodexResult: Sendable {
    let usage: UsageSnapshot
    let credits: CreditsSnapshot?
    let dashboard: OpenAIDashboardSnapshot
}

enum CodexCookieImportMode: Sendable {
    case browser
    case manual(cookieHeader: String)
}

struct CodexCookieImportInput: Sendable {
    let mode: CodexCookieImportMode
    let accountEmail: String?
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

private struct OpenAIWebOptions: Sendable {
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
    static func resolveCookieImportInput(
        settings: ProviderSettingsSnapshot.CodexProviderSettings?,
        fallbackAccountEmail: String?) -> CodexCookieImportInput
    {
        let fallback = fallbackAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings?.cookieSource == .manual,
           let manual = settings?.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !manual.isEmpty
        {
            return CodexCookieImportInput(mode: .manual(cookieHeader: manual), accountEmail: nil)
        }
        return CodexCookieImportInput(mode: .browser, accountEmail: fallback?.isEmpty == false ? fallback : nil)
    }

    @MainActor
    fileprivate static func fetchOpenAIWebCodex(
        importInput: CodexCookieImportInput,
        fetcher: UsageFetcher,
        options: OpenAIWebOptions,
        browserDetection: BrowserDetection) async throws -> OpenAIWebCodexResult
    {
        let logger = WebLogBuffer(verbose: options.verbose)
        let log: @MainActor (String) -> Void = { line in
            logger.append(line)
        }
        let dashboard = try await Self.fetchOpenAIWebDashboard(
            importInput: importInput,
            fetcher: fetcher,
            options: options,
            browserDetection: browserDetection,
            logger: log)
        guard let usage = dashboard.toUsageSnapshot(provider: .codex, accountEmail: importInput.accountEmail) else {
            throw OpenAIWebCodexError.missingUsage
        }
        let credits = dashboard.toCreditsSnapshot()
        return OpenAIWebCodexResult(usage: usage, credits: credits, dashboard: dashboard)
    }

    @MainActor
    fileprivate static func fetchOpenAIWebDashboard(
        importInput: CodexCookieImportInput,
        fetcher: UsageFetcher,
        options: OpenAIWebOptions,
        browserDetection: BrowserDetection,
        logger: @MainActor @escaping (String) -> Void) async throws -> OpenAIDashboardSnapshot
    {
        let fallback = fetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexEmail = importInput.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (fallback?.isEmpty == false ? fallback : nil)
        let allowAnyAccount = codexEmail == nil

        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: browserDetection)
        let importResult: OpenAIDashboardBrowserCookieImporter.ImportResult = switch importInput.mode {
        case let .manual(cookieHeader):
            try await importer.importManualCookies(
                cookieHeader: cookieHeader,
                intoAccountEmail: codexEmail,
                allowAnyAccount: allowAnyAccount,
                logger: logger)
        case .browser:
            try await importer.importBestCookies(
                intoAccountEmail: codexEmail,
                allowAnyAccount: allowAnyAccount,
                logger: logger)
        }
        let effectiveEmail = codexEmail ?? importResult.signedInEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
            accountEmail: effectiveEmail,
            logger: logger,
            debugDumpHTML: options.debugDumpHTML,
            timeout: options.timeout)
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
