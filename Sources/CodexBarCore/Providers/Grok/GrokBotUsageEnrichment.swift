import Foundation

/// Presents Cursor's Bot allowance under Grok without adopting Cursor identity or billing data.
package struct GrokBotUsageEnrichment: ProviderFetchStrategy {
    typealias BotFetch = @Sendable (ProviderFetchContext) async throws -> NamedRateWindow

    let base: (any ProviderFetchStrategy)?
    let fetchBot: BotFetch

    package var id: String {
        self.base?.id ?? "grok.bot"
    }

    package var kind: ProviderFetchKind {
        self.base?.kind ?? .web
    }

    init(base: (any ProviderFetchStrategy)? = nil, fetchBot: @escaping BotFetch = Self.fetchBotUsage) {
        self.base = base
        self.fetchBot = fetchBot
    }

    package func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.grok?.grokBotUsageEnabled == true else { return false }
        if let base = self.base { return await base.isAvailable(context) }
        // Provider-specific by design: the linked Cursor session supplies the Bot-only fallback.
        return Self.cursorCookieSource(context) != .off
    }

    package func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Required Grok billing completes first; optional Bot errors cannot fail that result.
        let result = try await self.base?.fetch(context)
        guard context.settings?.grok?.grokBotUsageEnabled == true else {
            if let result { return result }
            throw ProviderFetchError.noAvailableStrategy(.grok)
        }
        try Task.checkCancellation()
        let task = Task { try await self.fetchBot(context) }
        let outcome = await BoundedTaskJoin(sourceTask: task).value(joinGrace: .seconds(6))
        try Task.checkCancellation()
        let window: NamedRateWindow
        let botDiagnostic: String?
        switch outcome {
        case let .value(value):
            window = value
            botDiagnostic = nil
        case let .failure(error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            guard result != nil else { throw error }
            window = Self.unavailableWindow
            botDiagnostic = Self.failureDiagnostic(error)
        case .timedOut:
            guard result != nil else { throw URLError(.timedOut) }
            window = Self.unavailableWindow
            botDiagnostic = "Grok Bot lookup timed out."
        }
        if let result {
            let clean = Self.removingBotUsage(from: result.usage)
            let diagnostic = [result.diagnostic, botDiagnostic].compactMap(\.self).joined(separator: " ")
            return result.replacing(
                usage: clean.replacing(
                    extraRateWindows: .value((clean.extraRateWindows ?? []) + [window])),
                diagnostic: diagnostic.isEmpty ? nil : diagnostic)
        }
        return self.makeResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                extraRateWindows: [window],
                updatedAt: Date()),
            sourceLabel: "grok-bot-cursor",
            diagnostic: "Grok subscription usage is unavailable. Showing Grok Bot's linked Cursor allowance only.")
    }

    package func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        // Preserve the normal Grok source order, then allow the Bot-only fallback.
        self.base != nil && !(error is CancellationError) && (error as? URLError)?.code != .cancelled
    }

    package func diagnostic(forPriorFailure error: Error) -> String? {
        if let base = self.base { return base.diagnostic(forPriorFailure: error) }
        return "Grok subscription usage is unavailable. Showing Grok Bot's linked Cursor allowance only."
    }

    package static func removingBotUsage(from usage: UsageSnapshot) -> UsageSnapshot {
        let extras = usage.extraRateWindows?.filter { $0.id != CursorSandUsageStatus.extraWindowID }
        return usage.replacing(extraRateWindows: .value(extras?.isEmpty == false ? extras : nil))
    }

    private static var unavailableWindow: NamedRateWindow {
        NamedRateWindow(
            id: CursorSandUsageStatus.extraWindowID,
            title: CursorSandUsageStatus.extraWindowTitle,
            window: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            usageKnown: false)
    }

    private static func failureDiagnostic(_ error: Error) -> String {
        if (error as? URLError)?.code == .timedOut { return "Grok Bot lookup timed out." }
        if let error = error as? CursorStatusProbeError {
            switch error {
            case .noSessionCookie:
                return "Grok Bot needs the linked Cursor account. Sign in under Cursor settings."
            case .notLoggedIn:
                return "Grok Bot's linked Cursor session expired. Sign in again under Cursor settings."
            case .parseFailed:
                return "Grok Bot's linked Cursor account did not return a readable allowance."
            case let .networkError(message):
                if message.hasPrefix("HTTP "), let status = Int(message.dropFirst(5)), (100...599).contains(status) {
                    return "Grok Bot lookup failed (HTTP \(status))."
                }
            default:
                break
            }
        }
        return "Grok Bot lookup failed. Try refreshing again."
    }

    static func fetchBotUsage(_ context: ProviderFetchContext) async throws -> NamedRateWindow {
        try await self.fetchBotUsage(context, makeProbe: {
            CursorStatusProbe(timeout: 5, browserDetection: context.browserDetection)
        })
    }

    static func fetchBotUsage(
        _ context: ProviderFetchContext,
        makeProbe: @Sendable () -> CursorStatusProbe) async throws -> NamedRateWindow
    {
        let settings = context.settings?.cursor
        let source = Self.cursorCookieSource(context)
        guard source != .off else { throw CursorStatusProbeError.noSessionCookie }
        let manual: String?
        if source == .manual {
            guard let header = CookieHeaderNormalizer.normalize(settings?.manualCookieHeader) else {
                throw CursorStatusProbeError.noSessionCookie
            }
            manual = header
        } else {
            manual = nil
        }
        let probe = makeProbe()
        let logger: ((String) -> Void)? = context.verbose
            ? { message in CodexBarLog.logger(LogCategories.provider(.grok)).verbose(message) }
            : nil
        let status = try await probe.fetchGrokBotUsage(
            cookieHeaderOverride: manual,
            allowAppAuthFallback: context.settings?.grok?.grokBotSourceMode != .web,
            logger: logger)
        guard let window = status.extraRateWindow(resetDescription: { $0.formatted() }) else {
            throw CursorStatusProbeError.parseFailed("No Grok Bot allowance found for the linked Cursor account.")
        }
        return window
    }

    private static func cursorCookieSource(_ context: ProviderFetchContext) -> ProviderCookieSource {
        // Provider-specific by design: Bot authentication follows Cursor's cookie policy and explicit opt-out.
        let source = context.settings?.cursor?.cookieSource ?? .auto
        guard source != .off else { return .off }
        return context.settings?.grok?.grokBotCursorCookieSource ?? source
    }
}
