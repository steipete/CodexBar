import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches live billing data from `api.commandcode.ai` using a better-auth session
/// cookie scraped from the user's browser.
public enum CommandCodeUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.commandcodeUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let apiBase = URL(string: "https://api.commandcode.ai")!
    private static let creditsPath = "/internal/billing/credits"
    private static let subscriptionsPath = "/internal/billing/subscriptions"
    private static let webOrigin = "https://commandcode.ai"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public static func fetchUsage(
        cookieHeader: String,
        session: URLSession = .shared,
        now: Date = Date()) async throws -> CommandCodeUsageSnapshot
    {
        async let creditsResult = self.fetchCredits(cookieHeader: cookieHeader, session: session)
        async let subscriptionResult = self.fetchSubscription(cookieHeader: cookieHeader, session: session)

        let credits = try await creditsResult
        let subscription = try await subscriptionResult

        let plan: CommandCodePlanCatalog.Plan? = subscription.flatMap { sub in
            CommandCodePlanCatalog.plan(forID: sub.planID)
        }

        // If we got an active subscription with an unrecognised plan ID, surface that
        // explicitly rather than silently dropping the totals row.
        if let sub = subscription, sub.status.lowercased() == "active", plan == nil {
            Self.log.error("Unknown CommandCode planId: \(sub.planID)")
            throw CommandCodeUsageError.unknownPlan(sub.planID)
        }

        return CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: credits.monthlyCredits,
            purchasedCredits: credits.purchasedCredits,
            premiumMonthlyCredits: credits.premiumMonthlyCredits,
            opensourceMonthlyCredits: credits.opensourceMonthlyCredits,
            plan: plan,
            billingPeriodEnd: subscription?.currentPeriodEnd,
            subscriptionStatus: subscription?.status,
            updatedAt: now)
    }

    // MARK: - Endpoints

    struct CreditsPayload: Sendable {
        let monthlyCredits: Double
        let purchasedCredits: Double
        let premiumMonthlyCredits: Double
        let opensourceMonthlyCredits: Double
    }

    struct SubscriptionPayload: Sendable {
        let planID: String
        let status: String
        let currentPeriodEnd: Date?
    }

    private static func fetchCredits(
        cookieHeader: String,
        session: URLSession) async throws -> CreditsPayload
    {
        let url = self.apiBase.appendingPathComponent(self.creditsPath)
        let data = try await self.send(url: url, cookieHeader: cookieHeader, session: session)
        return try self.parseCredits(data: data)
    }

    private static func fetchSubscription(
        cookieHeader: String,
        session: URLSession) async throws -> SubscriptionPayload?
    {
        let url = self.apiBase.appendingPathComponent(self.subscriptionsPath)
        let data = try await self.send(url: url, cookieHeader: cookieHeader, session: session)
        return try self.parseSubscription(data: data)
    }

    private static func send(
        url: URL,
        cookieHeader: String,
        session: URLSession) async throws -> Data
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

        let response: URLResponse
        let data: Data
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CommandCodeUsageError.networkError(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommandCodeUsageError.networkError("Invalid response")
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CommandCodeUsageError.invalidCredentials
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("CommandCode \(url.path) → \(httpResponse.statusCode): \(body)")
            throw CommandCodeUsageError.apiError(httpResponse.statusCode)
        }
        return data
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
        return CreditsPayload(
            monthlyCredits: monthly,
            purchasedCredits: self.double(from: credits["purchasedCredits"]) ?? 0,
            premiumMonthlyCredits: self.double(from: credits["premiumMonthlyCredits"]) ?? 0,
            opensourceMonthlyCredits: self.double(from: credits["opensourceMonthlyCredits"]) ?? 0)
    }

    static func parseSubscription(data: Data) throws -> SubscriptionPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: invalid JSON")
        }
        // {"success":true,"data":{...}} when subscribed; data may be missing or null on free tier.
        guard root["success"] as? Bool ?? false else {
            return nil
        }
        guard let data = root["data"] as? [String: Any] else {
            return nil
        }
        guard let planID = data["planId"] as? String, !planID.isEmpty else {
            throw CommandCodeUsageError.parseFailed("Subscriptions: missing planId")
        }
        let status = (data["status"] as? String) ?? "unknown"
        let periodEnd = self.date(from: data["currentPeriodEnd"])
        return SubscriptionPayload(planID: planID, status: status, currentPeriodEnd: periodEnd)
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
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
