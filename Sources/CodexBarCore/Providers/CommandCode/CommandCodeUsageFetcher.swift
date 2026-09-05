import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches live billing data from `api.commandcode.ai` using a better-auth session
/// cookie scraped from the user's browser.
public enum CommandCodeUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.provider(.commandcode, scope: "usage"))
    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let subscriptionGraceSeconds: TimeInterval = 2
    private static let defaultAPIBase = URL(string: "https://api.commandcode.ai")!
    /// Test override for the billing endpoint, matching `MIMO_API_URL` and `WAYFINDER_GATEWAY_URL`.
    /// HTTPS anywhere, or plain HTTP on loopback, so a local stub can drive the real transport.
    static let apiURLEnvironmentKey = "COMMANDCODE_API_URL"
    private static let creditsPath = "/internal/billing/credits"
    private static let subscriptionsPath = "/internal/billing/subscriptions"
    private static let webOrigin = "https://commandcode.ai"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static let sharedPlanCache = CommandCodePlanCache()
    @TaskLocal private static var planCacheOverrideForTesting: CommandCodePlanCache?

    private static var planCache: CommandCodePlanCache {
        self.planCacheOverrideForTesting ?? self.sharedPlanCache
    }

    public static func fetchUsage(
        cookieHeader: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> CommandCodeUsageSnapshot
    {
        try await self.fetchUsage(
            cookieHeader: cookieHeader,
            transport: transport,
            now: now,
            subscriptionGrace: .seconds(self.subscriptionGraceSeconds))
    }

    static func _fetchUsageForTesting(
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date(),
        subscriptionGrace: Duration) async throws -> CommandCodeUsageSnapshot
    {
        try await self.fetchUsage(
            cookieHeader: cookieHeader,
            transport: transport,
            now: now,
            subscriptionGrace: subscriptionGrace)
    }

    #if DEBUG
    /// Runs `operation` against a plan memory of its own, so a test can neither read nor write the
    /// process-wide one.
    static func withIsolatedPlanCacheForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$planCacheOverrideForTesting.withValue(CommandCodePlanCache()) {
            try await operation()
        }
    }
    #endif

    private static func fetchUsage(
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        now: Date,
        subscriptionGrace: Duration) async throws -> CommandCodeUsageSnapshot
    {
        let (credits, subscription, subscriptionEnrichmentUnavailable) = try await self.fetchPayloads(
            cookieHeader: cookieHeader,
            transport: transport,
            subscriptionGrace: subscriptionGrace)

        let plan: CommandCodePlanCatalog.Plan? = subscription.flatMap { sub in
            CommandCodePlanCatalog.plan(forID: sub.planID)
        }

        // If we got an active subscription with an unrecognised plan ID, surface that
        // explicitly rather than silently dropping the totals row.
        if let sub = subscription, sub.status.lowercased() == "active", plan == nil {
            Self.log.error("Unknown CommandCode planId: \(sub.planID)")
            // That answer also proves any remembered plan is superseded, so a later timed-out
            // refresh must not keep sizing the lane from it.
            await self.planCache.clear(
                fingerprint: CookieHeaderCache.credentialFingerprint(cookieHeader),
                now: now)
            throw CommandCodeUsageError.unknownPlan(sub.planID)
        }

        let resolved = await self.resolveSubscription(
            subscription: subscription,
            enrichmentUnavailable: subscriptionEnrichmentUnavailable,
            cookieHeader: cookieHeader,
            now: now)

        return CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: credits.monthlyCredits,
            purchasedCredits: credits.purchasedCredits,
            premiumMonthlyCredits: credits.premiumMonthlyCredits,
            opensourceMonthlyCredits: credits.opensourceMonthlyCredits,
            fiveHourWindow: credits.fiveHourWindow,
            weeklyWindow: credits.weeklyWindow,
            plan: resolved.plan,
            billingPeriodEnd: resolved.periodEnd,
            subscriptionStatus: resolved.status,
            subscriptionEnrichmentUnavailable: subscriptionEnrichmentUnavailable,
            updatedAt: now)
    }

    /// Sizes the monthly grant from this refresh when the subscription lookup answered, and from the
    /// plan remembered for this billing period when it did not. The percentage always comes from the
    /// fresh credits response, so a remembered plan reports current spend rather than a stale reading.
    ///
    /// Only the grant size and its period are remembered. `subscriptionStatus` describes the current
    /// subscription, so the remembered path reports it as unknown rather than repeating an old value.
    private static func resolveSubscription(
        subscription: SubscriptionPayload?,
        enrichmentUnavailable: Bool,
        cookieHeader: String,
        now: Date) async -> (plan: CommandCodePlanCatalog.Plan?, periodEnd: Date?, status: String?)
    {
        let fingerprint = CookieHeaderCache.credentialFingerprint(cookieHeader)
        guard enrichmentUnavailable else {
            guard let subscription,
                  let plan = CommandCodePlanCatalog.plan(forID: subscription.planID)
            else {
                // The lookup succeeded and reported no subscription: the free tier owns this account
                // until a later refresh says otherwise.
                await self.planCache.clear(fingerprint: fingerprint, now: now)
                return (nil, subscription?.currentPeriodEnd, subscription?.status)
            }
            await self.planCache.store(
                plan: plan,
                periodEnd: subscription.currentPeriodEnd,
                fingerprint: fingerprint,
                now: now)
            return (plan, subscription.currentPeriodEnd, subscription.status)
        }
        guard let remembered = await self.planCache.entry(fingerprint: fingerprint, now: now) else {
            return (nil, nil, nil)
        }
        Self.log.debug("Command Code monthly grant sized from the remembered plan")
        return (remembered.plan, remembered.periodEnd, nil)
    }

    private static func fetchPayloads(
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        subscriptionGrace: Duration) async throws -> (CreditsPayload, SubscriptionPayload?, Bool)
    {
        let subscriptionTask = Task<SubscriptionPayload?, Error> {
            try await self.fetchSubscription(cookieHeader: cookieHeader, transport: transport)
        }
        let credits: CreditsPayload
        do {
            credits = try await withTaskCancellationHandler {
                try await self.fetchCredits(cookieHeader: cookieHeader, transport: transport)
            } onCancel: {
                subscriptionTask.cancel()
            }
        } catch {
            subscriptionTask.cancel()
            throw error
        }

        do {
            try Task.checkCancellation()
        } catch {
            subscriptionTask.cancel()
            throw error
        }
        let race = BoundedTaskJoin(sourceTask: subscriptionTask)
        switch await race.value(joinGrace: subscriptionGrace) {
        case let .value(subscription):
            try Task.checkCancellation()
            return (credits, subscription, false)
        case .timedOut:
            try Task.checkCancellation()
            Self.log.warning("Command Code subscription enrichment timed out")
            return (credits, nil, true)
        case let .failure(error):
            subscriptionTask.cancel()
            try Task.checkCancellation()
            Self.log.warning("Command Code subscription enrichment failed: \(error.localizedDescription)")
            return (credits, nil, true)
        }
    }

    // MARK: - Endpoints

    struct CreditsPayload {
        let monthlyCredits: Double
        let purchasedCredits: Double
        let premiumMonthlyCredits: Double
        let opensourceMonthlyCredits: Double
        let fiveHourWindow: RateWindow?
        let weeklyWindow: RateWindow?
    }

    struct SubscriptionPayload {
        let planID: String
        let status: String
        let currentPeriodEnd: Date?
    }

    private static func fetchCredits(
        cookieHeader: String,
        transport: any ProviderHTTPTransport) async throws -> CreditsPayload
    {
        let url = self.apiBase().appendingPathComponent(self.creditsPath)
        let data = try await self.send(url: url, cookieHeader: cookieHeader, transport: transport)
        return try self.parseCredits(data: data)
    }

    private static func fetchSubscription(
        cookieHeader: String,
        transport: any ProviderHTTPTransport) async throws -> SubscriptionPayload?
    {
        let url = self.apiBase().appendingPathComponent(self.subscriptionsPath)
        let data = try await self.send(url: url, cookieHeader: cookieHeader, transport: transport)
        return try self.parseSubscription(data: data)
    }

    /// The billing endpoint for this process. An invalid override falls back to production, the
    /// same way `WayfinderSettingsReader.baseURL` treats a rejected value.
    static func apiBase(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        guard let raw = environment[self.apiURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            return self.defaultAPIBase
        }
        return ProviderEndpointOverrideValidator()
            .validatedURLAllowingLoopbackHTTP(raw) ?? self.defaultAPIBase
    }

    private static func send(
        url: URL,
        cookieHeader: String,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(self.webOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(self.webOrigin)/", forHTTPHeaderField: "Referer")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw CommandCodeUsageError.networkError(error.localizedDescription)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CommandCodeUsageError.invalidCredentials
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            Self.log.error("CommandCode \(url.path) → \(response.statusCode): \(body)")
            throw CommandCodeUsageError.apiError(response.statusCode)
        }
        return response.data
    }

    // MARK: - Parsing

    static func parseCredits(data: Data) throws -> CreditsPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Credits: invalid JSON")
        }
        guard let credits = root["credits"] as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Credits: missing 'credits' object")
        }
        guard let monthly = self.double(from: credits["monthlyCredits"]) else {
            throw CommandCodeUsageError.parseFailed("Credits: missing monthlyCredits")
        }
        let windowLimits = (root["windowLimits"] as? [String: Any])
            ?? (credits["windowLimits"] as? [String: Any])
        return CreditsPayload(
            monthlyCredits: monthly,
            purchasedCredits: self.double(from: credits["purchasedCredits"]) ?? 0,
            premiumMonthlyCredits: self.double(from: credits["premiumMonthlyCredits"]) ?? 0,
            opensourceMonthlyCredits: self.double(from: credits["opensourceMonthlyCredits"]) ?? 0,
            fiveHourWindow: self.rateWindow(
                from: windowLimits?["fiveHour"],
                windowMinutes: 5 * 60),
            weeklyWindow: self.rateWindow(
                from: windowLimits?["weekly"],
                windowMinutes: 7 * 24 * 60))
    }

    static func parseSubscription(data: Data) throws -> SubscriptionPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: invalid JSON")
        }
        // Only an explicit successful null response identifies the free tier. Failure envelopes are transient.
        guard let success = root["success"] as? Bool else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: missing success flag")
        }
        guard success else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: unsuccessful response")
        }
        guard let dataValue = root["data"] else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: missing data")
        }
        if dataValue is NSNull {
            return nil
        }
        guard let data = dataValue as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: invalid data")
        }
        guard let planID = data["planId"] as? String, !planID.isEmpty else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: missing planId")
        }
        let status = (data["status"] as? String) ?? "unknown"
        let periodEnd = self.date(from: data["currentPeriodEnd"])
        return SubscriptionPayload(planID: planID, status: status, currentPeriodEnd: periodEnd)
    }

    private static func rateWindow(from value: Any?, windowMinutes: Int) -> RateWindow? {
        guard let limit = value as? [String: Any],
              let cap = self.double(from: limit["cap"]),
              cap > 0
        else {
            return nil
        }
        let used = self.double(from: limit["used"]) ?? 0
        return RateWindow(
            usedPercent: UsagePercent(used: used, limit: cap).displayClamped,
            windowMinutes: windowMinutes,
            resetsAt: self.date(from: limit["resetAt"]),
            resetDescription: nil)
    }

    // MARK: - Value coercion

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        default:
            return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = self.double(from: value), timestamp > 0 {
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
