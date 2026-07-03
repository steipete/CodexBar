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
    public let updatedAt: Date

    public init(
        planName: String?,
        priceLabel: String?,
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        updatedAt: Date = Date())
    {
        self.planName = planName
        self.priceLabel = priceLabel
        self.fiveHour = fiveHour
        self.weekly = weekly
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
            updatedAt: self.updatedAt,
            identity: identity)
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

public enum SakanaUsageFetcher {
    private static let billingURL = URL(string: "https://console.sakana.ai/billing")!
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
        now: Date = Date()) async throws -> SakanaUsageSnapshot
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
        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 || (300..<400).contains(response.statusCode) {
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
        return try self.parseBillingHTML(html, now: now)
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
