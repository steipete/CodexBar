import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SakanaUsageSnapshot: Sendable {
    public struct QuotaWindow: Sendable, Equatable {
        public let usedPercent: Double
        public let resetsAt: Date?

        public init(usedPercent: Double, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public let planName: String?
    public let priceLabel: String?
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    public let payAsYouGo: SakanaPayAsYouGoSnapshot?
    public let updatedAt: Date

    public init(
        planName: String?,
        priceLabel: String?,
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        payAsYouGo: SakanaPayAsYouGoSnapshot? = nil,
        updatedAt: Date = Date())
    {
        self.planName = planName
        self.priceLabel = priceLabel
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.payAsYouGo = payAsYouGo
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.fiveHour.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: 5 * 60,
                resetsAt: window.resetsAt,
                resetDescription: nil)
        }
        let secondary = self.weekly.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: window.resetsAt,
                resetDescription: nil)
        }
        let planLabel = [self.planName, self.priceLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let identity = ProviderIdentitySnapshot(
            providerID: .sakana,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: planLabel.isEmpty ? nil : planLabel)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            sakanaPayAsYouGo: self.payAsYouGo,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

/// Sakana "Pay as you go" tab data (prepaid credit balance + a rolling usage total for the
/// console's selected date range). Fetched best-effort alongside the subscription quota windows;
/// absence never fails the primary Sakana fetch.
public struct SakanaPayAsYouGoSnapshot: Codable, Equatable, Sendable {
    public let creditBalance: Double
    public let periodUsageTotal: Double?
    /// Raw label from the console's date-range picker (e.g. "Jun 02, 2026 - Jul 01, 2026").
    public let periodLabel: String?

    public init(
        creditBalance: Double,
        periodUsageTotal: Double? = nil,
        periodLabel: String? = nil)
    {
        self.creditBalance = creditBalance
        self.periodUsageTotal = periodUsageTotal
        self.periodLabel = periodLabel
    }

    public var balanceDetail: String {
        UsageFormatter.usdString(self.creditBalance)
    }
}

public enum SakanaUsageError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case loginRequired
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "Missing Sakana cookie header (SAKANA_COOKIE)."
        case .loginRequired:
            "Sakana login is required."
        case let .apiError(code):
            "Sakana billing fetch failed (HTTP \(code))."
        case let .parseFailed(message):
            "Failed to parse Sakana billing page: \(message)"
        }
    }
}

private final class SakanaPayAsYouGoResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SakanaPayAsYouGoSnapshot?

    func complete(with result: SakanaPayAsYouGoSnapshot?) {
        self.lock.withLock {
            self.result = result
        }
    }

    func valueIfCompleted() -> SakanaPayAsYouGoSnapshot? {
        self.lock.withLock { self.result }
    }
}

public enum SakanaUsageFetcher {
    private static let billingURL = URL(string: "https://console.sakana.ai/billing")!
    private static let payAsYouGoURL = URL(string: "https://console.sakana.ai/billing?tab=payAsYouGo")!
    /// Optional enrichment gets a small shared budget from the start of the primary request. A slow
    /// primary therefore never waits, while a fast primary can briefly collect an in-flight result.
    private static let payAsYouGoEnrichmentBudget: Duration = .milliseconds(200)
    private static let defaultTransport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = ProviderHTTPClient.redirectGuardedSession(configuration: configuration)
        return ProviderHTTPClient(session: session)
    }()

    public static func fetchUsage(
        cookieHeader: String,
        session transportOverride: (any ProviderHTTPTransport)? = nil,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        includeOptionalUsage: Bool = true) async throws -> SakanaUsageSnapshot
    {
        guard let cookieHeader = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw SakanaUsageError.missingCookie
        }

        var request = URLRequest(url: self.billingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let transport = transportOverride ?? self.defaultTransport
        let fetchStartedAt = ContinuousClock.now
        let payAsYouGoResult = includeOptionalUsage ? SakanaPayAsYouGoResult() : nil
        let payAsYouGoTask: Task<Void, Error>? = if let payAsYouGoResult {
            Task {
                let result = await self.boundedFetchPayAsYouGo(
                    cookieHeader: cookieHeader,
                    transport: transport,
                    timeout: timeout)
                payAsYouGoResult.complete(with: result)
            }
        } else {
            nil
        }

        return try await withTaskCancellationHandler {
            do {
                let response = try await transport.response(for: request)
                if response.statusCode == 401 || response.statusCode == 403 ||
                    (300..<400).contains(response.statusCode)
                {
                    throw SakanaUsageError.loginRequired
                }
                guard response.response.url?.scheme?.lowercased() == "https",
                      response.response.url?.host?.lowercased() == self.billingURL.host?.lowercased()
                else {
                    throw SakanaUsageError.loginRequired
                }
                guard response.statusCode == 200 else {
                    throw SakanaUsageError.apiError(response.statusCode)
                }
                guard let html = String(data: response.data, encoding: .utf8), !html.isEmpty else {
                    throw SakanaUsageError.parseFailed("Billing page response was empty.")
                }
                let snapshot = try self.parseBillingHTML(html, now: now)
                let payAsYouGo = await self.collectPayAsYouGo(
                    task: payAsYouGoTask,
                    result: payAsYouGoResult,
                    fetchStartedAt: fetchStartedAt)
                try Task.checkCancellation()
                return SakanaUsageSnapshot(
                    planName: snapshot.planName,
                    priceLabel: snapshot.priceLabel,
                    fiveHour: snapshot.fiveHour,
                    weekly: snapshot.weekly,
                    payAsYouGo: payAsYouGo,
                    updatedAt: snapshot.updatedAt)
            } catch {
                payAsYouGoTask?.cancel()
                throw error
            }
        } onCancel: {
            payAsYouGoTask?.cancel()
        }
    }

    private static func collectPayAsYouGo(
        task: Task<Void, Error>?,
        result: SakanaPayAsYouGoResult?,
        fetchStartedAt: ContinuousClock.Instant) async -> SakanaPayAsYouGoSnapshot?
    {
        guard let task, let result else { return nil }
        let elapsed = fetchStartedAt.duration(to: .now)
        let remainingBudget = elapsed < self.payAsYouGoEnrichmentBudget
            ? self.payAsYouGoEnrichmentBudget - elapsed
            : .zero
        if remainingBudget > .zero {
            let join = BoundedTaskJoin(sourceTask: task)
            _ = await join.value(joinGrace: remainingBudget)
        }
        task.cancel()
        return result.valueIfCompleted()
    }

    /// Caps the lifetime of the optional Pay-as-you-go fetch. The primary fetch only consumes an
    /// already-completed or shared-budget result and cancels this task otherwise.
    private static let payAsYouGoJoinGrace: Duration = .seconds(5)

    private static func boundedFetchPayAsYouGo(
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval) async -> SakanaPayAsYouGoSnapshot?
    {
        await self.boundedFetch(timeout: self.payAsYouGoJoinGrace) {
            await self.fetchPayAsYouGo(cookieHeader: cookieHeader, transport: transport, timeout: timeout)
        }
    }

    static func _boundedFetchPayAsYouGoForTesting(
        timeout: Duration,
        operation: @escaping @Sendable () async -> SakanaPayAsYouGoSnapshot?) async -> SakanaPayAsYouGoSnapshot?
    {
        await self.boundedFetch(timeout: timeout, operation: operation)
    }

    private static func boundedFetch(
        timeout: Duration,
        operation: @escaping @Sendable () async -> SakanaPayAsYouGoSnapshot?) async -> SakanaPayAsYouGoSnapshot?
    {
        let sourceTask = Task<SakanaPayAsYouGoSnapshot?, Error> {
            await operation()
        }
        let race = BoundedTaskJoin(sourceTask: sourceTask)
        switch await race.value(joinGrace: timeout) {
        case let .value(result):
            return result
        case .timedOut, .failure:
            return nil
        }
    }

    /// Best-effort fetch of the Pay-as-you-go tab. Never throws: subscription quota windows are
    /// the primary, historically-supported contract of this fetcher, and an account without PAYG
    /// credit (or a console change that breaks this parser) must not regress that core behavior.
    private static func fetchPayAsYouGo(
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        timeout: TimeInterval) async -> SakanaPayAsYouGoSnapshot?
    {
        var request = URLRequest(url: self.payAsYouGoURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        guard let response = try? await transport.response(for: request),
              response.statusCode == 200,
              response.response.url?.scheme?.lowercased() == "https",
              response.response.url?.host?.lowercased() == self.billingURL.host?.lowercased(),
              let html = String(data: response.data, encoding: .utf8), !html.isEmpty
        else {
            return nil
        }
        return self.parsePayAsYouGoHTML(html)
    }

    static func parsePayAsYouGoHTML(_ html: String) -> SakanaPayAsYouGoSnapshot? {
        guard let balanceText = self.capture(
            pattern: #"<h2[^>]*>\s*Credit balance\s*</h2>[\s\S]{0,900}?<p[^>]*tabular-nums[^"]*"[^>]*>"# +
                #"\$?([0-9][0-9,]*(?:\.[0-9]+)?)</p>"#,
            in: html),
            let creditBalance = self.parseAmount(balanceText)
        else {
            return nil
        }

        let usageTotalText = self.capture(
            pattern: #"<h2[^>]*>\s*Usage\s*</h2>\s*<span[^>]*>\s*Total(?:<!--\s*-->)?:\s*"# +
                #"(?:<!--\s*-->)?\$?([0-9][0-9,]*(?:\.[0-9]+)?)\s*</span>"#,
            in: html)
        let periodUsageTotal = usageTotalText.flatMap(self.parseAmount)

        let periodLabel = self.capture(
            pattern: #"aria-label="Usage date range"[^>]*>([\s\S]*?)</button>"#,
            in: html).map(self.stripHTMLComments)

        return SakanaPayAsYouGoSnapshot(
            creditBalance: creditBalance,
            periodUsageTotal: periodUsageTotal,
            periodLabel: periodLabel)
    }

    private static func parseAmount(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")), value.isFinite else {
            return nil
        }
        return value
    }

    /// Strips React's `<!-- -->` hydration boundary comments (inserted between separately
    /// interpolated JSX text nodes) and collapses the remaining whitespace.
    private static func stripHTMLComments(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"<!--.*?-->"#,
            with: "",
            options: .regularExpression)
        return stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseBillingHTML(
        _ html: String,
        now: Date = Date()) throws -> SakanaUsageSnapshot
    {
        let fiveHour = try self.parseWindow(label: "5-hour", html: html)
        let weekly = try self.parseWindow(label: "Weekly", html: html)
        guard fiveHour != nil || weekly != nil else {
            throw SakanaUsageError.parseFailed("Usage limit windows were not found.")
        }
        return SakanaUsageSnapshot(
            planName: self.parsePlanName(html),
            priceLabel: self.parsePlanPrice(html),
            fiveHour: fiveHour,
            weekly: weekly,
            updatedAt: now)
    }

    private static func parseWindow(
        label: String,
        html: String) throws -> SakanaUsageSnapshot.QuotaWindow?
    {
        guard let windowBody = self.windowBody(label: label, html: html) else { return nil }
        guard let percentText = self.capture(
            pattern: #"<p[^>]*>\s*([0-9]+(?:\.[0-9]+)?)% used\s*</p>"#,
            in: windowBody),
            let percent = Double(percentText),
            percent.isFinite,
            (0...100).contains(percent)
        else {
            throw SakanaUsageError.parseFailed("Invalid \(label) usage percentage.")
        }
        let resetText = self.capture(
            pattern: #"<p[^>]*>\s*Resets on ([^<]+?)\s*</p>"#,
            in: windowBody)
        return SakanaUsageSnapshot.QuotaWindow(
            usedPercent: percent,
            resetsAt: resetText.flatMap(self.parseResetDate))
    }

    private static func windowBody(label: String, html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let labelPattern = "<p[^>]*>\\s*\(escaped)\\s*</p>"
        guard let labelMatch = self.firstMatch(pattern: labelPattern, in: html),
              let bodyStart = Range(labelMatch.range, in: html)?.upperBound
        else {
            return nil
        }

        let bodyStartOffset = NSMaxRange(labelMatch.range)
        let bodyEnd = self.windowBoundary(after: bodyStartOffset, in: html) ?? html.endIndex
        let body = html[bodyStart..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : String(body)
    }

    private static func windowBoundary(after offset: Int, in html: String) -> String.Index? {
        let boundaryPattern =
            #"<p[^>]*>\s*(?:5-hour|Weekly)\s*</p>|<div[^>]*data-slot=(?:"card"|'card'|"card-title"|'card-title')[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: boundaryPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(location: offset, length: max(0, (html as NSString).length - offset))
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange) else {
            return nil
        }
        return Range(match.range, in: html)?.lowerBound
    }

    private static func parsePlanName(_ html: String) -> String? {
        self.capture(
            pattern: #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>\s*([^<]+?)\s*</span>"#,
            in: html)
    }

    private static func parsePlanPrice(_ html: String) -> String? {
        let pattern = #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>[^<]+</span>\s*"# +
            #"<span[^>]*>\s*([^<]+?)\s*</span>"#
        return self.capture(
            pattern: pattern,
            in: html)
    }

    /// The billing page always server-renders "Resets on <date>" in UTC — the client only
    /// corrects it to the viewer's local timezone after JS hydration, which this HTML-only
    /// scraper never runs. Parsing with any other timezone silently shifts every reset by the
    /// device's UTC offset (see steipete/CodexBar#1826).
    private static func parseResetDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.date(from: trimmed)
    }

    private static func capture(pattern: String, in html: String) -> String? {
        guard let match = self.firstMatch(pattern: pattern, in: html) else { return nil }
        return self.capture(1, in: html, match: match)
    }

    private static func firstMatch(pattern: String, in html: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.firstMatch(in: html, options: [], range: range)
    }

    private static func capture(_ index: Int, in html: String, match: NSTextCheckingResult) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: html)
        else {
            return nil
        }
        let value = html[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
