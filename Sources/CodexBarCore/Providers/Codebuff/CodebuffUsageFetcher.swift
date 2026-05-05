import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches live credit balance and subscription details from the Codebuff API.
/// Uses Bearer token auth against the public www.codebuff.com endpoints used by
/// the dashboard + the `codebuff` CLI.
public enum CodebuffUsageFetcher {
    private static let requestTimeoutSeconds: TimeInterval = 15
    /// Extra grace period to wait for the optional subscription endpoint after the
    /// primary usage call returns. Keeps the menu responsive when `/api/user/subscription`
    /// is slow or hangs while `/api/v1/usage` succeeds quickly.
    private static let subscriptionGraceSeconds: TimeInterval = 2

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeSubscription: Bool = true,
        session: URLSession = .shared) async throws -> CodebuffUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodebuffUsageError.missingCredentials
        }

        let baseURL = CodebuffSettingsReader.apiURL(environment: environment)

        let (usageValues, subscriptionValues) = try await self.fetchPayloads(
            apiKey: trimmed,
            baseURL: baseURL,
            includeSubscription: includeSubscription,
            session: session)

        return CodebuffUsageSnapshot(
            creditsUsed: usageValues.used,
            creditsTotal: usageValues.total,
            creditsRemaining: usageValues.remaining,
            weeklyUsed: subscriptionValues?.weeklyUsed,
            weeklyLimit: subscriptionValues?.weeklyLimit,
            weeklyResetsAt: subscriptionValues?.weeklyResetsAt,
            billingPeriodEnd: subscriptionValues?.billingPeriodEnd,
            nextQuotaReset: usageValues.nextQuotaReset,
            tier: subscriptionValues?.tier,
            subscriptionStatus: subscriptionValues?.status,
            autoTopUpEnabled: usageValues.autoTopupEnabled,
            accountEmail: subscriptionValues?.email,
            updatedAt: Date())
    }

    private static func fetchPayloads(
        apiKey: String,
        baseURL: URL,
        includeSubscription: Bool,
        session: URLSession) async throws -> (UsagePayload, SubscriptionPayload?)
    {
        try await withThrowingTaskGroup(of: FetchResult.self) { group in
            group.addTask {
                try await .usage(self.fetchUsagePayload(apiKey: apiKey, baseURL: baseURL, session: session))
            }
            if includeSubscription {
                group.addTask {
                    await .subscription(try? self.fetchSubscriptionPayload(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        session: session))
                }
            }

            var usageValues: UsagePayload?
            var subscriptionValues: SubscriptionPayload?
            var subscriptionFinished = !includeSubscription
            var timeoutStarted = false

            while let result = try await group.next() {
                switch result {
                case let .usage(payload):
                    usageValues = payload
                    if subscriptionFinished {
                        group.cancelAll()
                        return (payload, subscriptionValues)
                    }
                    if !timeoutStarted {
                        timeoutStarted = true
                        group.addTask {
                            let nanos = UInt64(max(0, Self.subscriptionGraceSeconds) * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: nanos)
                            return .subscriptionTimeout
                        }
                    }

                case let .subscription(payload):
                    subscriptionValues = payload
                    subscriptionFinished = true
                    if let usageValues {
                        group.cancelAll()
                        return (usageValues, payload)
                    }

                case .subscriptionTimeout:
                    if let usageValues {
                        group.cancelAll()
                        return (usageValues, subscriptionValues)
                    }
                }
            }

            throw CodebuffUsageError.networkError("Usage request did not complete")
        }
    }

    // MARK: - Endpoint helpers

    private enum FetchResult {
        case usage(UsagePayload)
        case subscription(SubscriptionPayload?)
        case subscriptionTimeout
    }

    struct UsagePayload {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let nextQuotaReset: Date?
        let autoTopupEnabled: Bool?
    }

    struct SubscriptionPayload {
        let status: String?
        let tier: String?
        let billingPeriodEnd: Date?
        let weeklyUsed: Double?
        let weeklyLimit: Double?
        let weeklyResetsAt: Date?
        let email: String?
    }

    static func usageURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("/api/v1/usage")
    }

    static func subscriptionURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("/api/user/subscription")
    }

    static func statusError(for statusCode: Int) -> CodebuffUsageError? {
        switch statusCode {
        case 401, 403: .unauthorized
        case 404: .endpointNotFound
        case 500...599: .serviceUnavailable(statusCode)
        default: nil
        }
    }

    static func parseUsagePayload(_ data: Data) throws -> UsagePayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodebuffUsageError.parseFailed("Invalid JSON")
        }

        let used = self.double(from: root["usage"]) ?? self.double(from: root["used"])
        let total = self.double(from: root["quota"]) ?? self.double(from: root["limit"])
        let remaining = self.double(from: root["remainingBalance"]) ?? self.double(from: root["remaining"])
        let reset = self.date(from: root["next_quota_reset"])
        let autoTopUp = root["autoTopupEnabled"] as? Bool ?? root["auto_topup_enabled"] as? Bool

        return UsagePayload(
            used: used,
            total: total,
            remaining: remaining,
            nextQuotaReset: reset,
            autoTopupEnabled: autoTopUp)
    }

    static func parseSubscriptionPayload(_ data: Data) throws -> SubscriptionPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodebuffUsageError.parseFailed("Invalid JSON")
        }

        let subscription = root["subscription"] as? [String: Any]
        let rateLimit = root["rateLimit"] as? [String: Any]

        let tier = self.string(from: subscription?["displayName"])
            ?? self.string(from: root["displayName"])
            ?? self.string(from: subscription?["tier"])
            ?? self.string(from: root["tier"])
            ?? self.string(from: subscription?["scheduledTier"])
        let status = subscription?["status"] as? String
        let email = root["email"] as? String ?? (root["user"] as? [String: Any])?["email"] as? String
        let billingPeriodEnd = self.date(from: subscription?["billingPeriodEnd"])
            ?? self.date(from: subscription?["currentPeriodEnd"])
        let weeklyUsed = self.double(from: rateLimit?["weeklyUsed"])
            ?? self.double(from: rateLimit?["used"])
        let weeklyLimit = self.double(from: rateLimit?["weeklyLimit"])
            ?? self.double(from: rateLimit?["limit"])
        let weeklyResetsAt = self.date(from: rateLimit?["weeklyResetsAt"])

        return SubscriptionPayload(
            status: status,
            tier: tier,
            billingPeriodEnd: billingPeriodEnd,
            weeklyUsed: weeklyUsed,
            weeklyLimit: weeklyLimit,
            weeklyResetsAt: weeklyResetsAt,
            email: email)
    }

    // MARK: - Test hooks

    static func _parseUsagePayloadForTesting(_ data: Data) throws -> UsagePayload {
        try self.parseUsagePayload(data)
    }

    static func _parseSubscriptionPayloadForTesting(_ data: Data) throws -> SubscriptionPayload {
        try self.parseSubscriptionPayload(data)
    }

    static func _statusErrorForTesting(_ statusCode: Int) -> CodebuffUsageError? {
        self.statusError(for: statusCode)
    }

    // MARK: - Networking

    private static func fetchUsagePayload(
        apiKey: String,
        baseURL: URL,
        session: URLSession) async throws -> UsagePayload
    {
        var request = URLRequest(url: self.usageURL(baseURL: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fingerprintId": "codexbar-usage"])

        let (data, response) = try await self.send(request: request, session: session)
        if let err = self.statusError(for: response.statusCode) {
            throw err
        }
        guard response.statusCode == 200 else {
            throw CodebuffUsageError.apiError(response.statusCode)
        }
        return try self.parseUsagePayload(data)
    }

    private static func fetchSubscriptionPayload(
        apiKey: String,
        baseURL: URL,
        session: URLSession) async throws -> SubscriptionPayload
    {
        var request = URLRequest(url: self.subscriptionURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.send(request: request, session: session)
        if let err = self.statusError(for: response.statusCode) {
            throw err
        }
        guard response.statusCode == 200 else {
            throw CodebuffUsageError.apiError(response.statusCode)
        }
        return try self.parseSubscriptionPayload(data)
    }

    private static func send(
        request: URLRequest,
        session: URLSession) async throws -> (Data, HTTPURLResponse)
    {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodebuffUsageError.networkError("Invalid response")
            }
            return (data, httpResponse)
        } catch let error as CodebuffUsageError {
            throw error
        } catch {
            throw CodebuffUsageError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Value parsing

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? raw : nil
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let raw = Double(trimmed), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return number.stringValue
        default:
            return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: trimmed) {
                return date
            }
            if let interval = Double(trimmed), interval.isFinite {
                return Self.dateFromNumeric(interval)
            }
            return nil
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? Self.dateFromNumeric(raw) : nil
        default:
            return nil
        }
    }

    private static func dateFromNumeric(_ value: Double) -> Date? {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }
}
