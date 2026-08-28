import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ZenMuxUsageError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case authenticationRejected
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Missing ZenMux Management API key. Add one in Settings or set ZENMUX_MANAGEMENT_API_KEY."
        case .authenticationRejected:
            "ZenMux rejected the Management API key. Standard inference API keys are not supported."
        case let .apiError(statusCode):
            "ZenMux Management API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse ZenMux usage: \(message)"
        }
    }
}

public struct ZenMuxUsageSnapshot: Sendable, Equatable {
    public struct QuotaWindow: Sendable, Equatable {
        public let usageFraction: Double
        public let resetsAt: Date?
        public let maxFlows: Double
        public let usedFlows: Double
        public let remainingFlows: Double

        public init(
            usageFraction: Double,
            resetsAt: Date?,
            maxFlows: Double,
            usedFlows: Double,
            remainingFlows: Double)
        {
            self.usageFraction = usageFraction
            self.resetsAt = resetsAt
            self.maxFlows = maxFlows
            self.usedFlows = usedFlows
            self.remainingFlows = remainingFlows
        }

        func rateWindow(windowMinutes: Int) -> RateWindow {
            RateWindow(
                usedPercent: (self.usageFraction * 100).clamped(to: 0...100),
                windowMinutes: windowMinutes,
                resetsAt: self.resetsAt,
                resetDescription: "\(Self.amount(self.usedFlows)) / \(Self.amount(self.maxFlows)) flows")
        }

        private static func amount(_ value: Double) -> String {
            value.rounded() == value
                ? String(format: "%.0f", value)
                : String(format: "%.2f", value)
        }
    }

    public let planTier: String
    public let subscriptionExpiresAt: Date?
    public let accountStatus: String
    public let fiveHour: QuotaWindow
    public let weekly: QuotaWindow
    public let updatedAt: Date

    public init(
        planTier: String,
        subscriptionExpiresAt: Date?,
        accountStatus: String,
        fiveHour: QuotaWindow,
        weekly: QuotaWindow,
        updatedAt: Date)
    {
        self.planTier = planTier
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.accountStatus = accountStatus
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot(paygBalanceUSD: Double? = nil) -> UsageSnapshot {
        let plan = self.planTier.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = self.accountStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = status.lowercased() == "healthy" || status.isEmpty
            ? Self.planLabel(plan)
            : [Self.planLabel(plan), status.capitalized].compactMap(\.self).joined(separator: " · ")

        return UsageSnapshot(
            primary: self.fiveHour.rateWindow(windowMinutes: 5 * 60),
            secondary: self.weekly.rateWindow(windowMinutes: 7 * 24 * 60),
            providerCost: paygBalanceUSD.map {
                ProviderCostSnapshot(
                    used: $0,
                    limit: 0,
                    currencyCode: "USD",
                    period: "ZenMux PAYG balance",
                    updatedAt: self.updatedAt)
            },
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .zenmux,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: loginMethod),
            dataConfidence: .exact)
    }

    private static func planLabel(_ tier: String) -> String? {
        guard !tier.isEmpty else { return nil }
        return "\(tier.capitalized) plan"
    }
}

public enum ZenMuxUsageFetcher {
    private static let managementBaseURL = URL(string: "https://zenmux.ai/api/v1/management")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        _ rawCredential: String,
        includePaygBalance: Bool,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> (usage: ZenMuxUsageSnapshot, paygBalanceUSD: Double?)
    {
        guard let credential = ZenMuxSettingsReader.cleaned(rawCredential) else {
            throw ZenMuxUsageError.notConfigured
        }
        let subscriptionData = try await self.get(
            pathComponents: ["subscription", "detail"],
            credential: credential,
            transport: transport)
        let usage = try self.parseSubscription(subscriptionData, now: now)

        guard includePaygBalance else { return (usage, nil) }
        let paygBalanceUSD: Double?
        do {
            let balanceData = try await self.get(
                pathComponents: ["payg", "balance"],
                credential: credential,
                transport: transport)
            paygBalanceUSD = try self.parsePaygBalanceUSD(balanceData)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch ZenMuxUsageError.authenticationRejected {
            throw ZenMuxUsageError.authenticationRejected
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            paygBalanceUSD = nil
        }
        return (usage, paygBalanceUSD)
    }

    private static func get(
        pathComponents: [String],
        credential: String,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        let url = pathComponents.reduce(self.managementBaseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ZenMuxUsageError.authenticationRejected
            }
            throw ZenMuxUsageError.apiError(response.statusCode)
        }
        return response.data
    }

    private static func parseSubscription(_ data: Data, now: Date) throws -> ZenMuxUsageSnapshot {
        let response: SubscriptionEnvelope
        do {
            response = try JSONDecoder().decode(SubscriptionEnvelope.self, from: data)
        } catch {
            throw ZenMuxUsageError.parseFailed(error.localizedDescription)
        }
        guard response.success else {
            throw ZenMuxUsageError.parseFailed("subscription response reported failure")
        }

        return ZenMuxUsageSnapshot(
            planTier: response.data.plan.tier,
            subscriptionExpiresAt: self.date(response.data.plan.expiresAt),
            accountStatus: response.data.accountStatus,
            fiveHour: response.data.quota5Hour.snapshot(),
            weekly: response.data.quota7Day.snapshot(),
            updatedAt: now)
    }

    private static func parsePaygBalanceUSD(_ data: Data) throws -> Double {
        let response: BalanceEnvelope
        do {
            response = try JSONDecoder().decode(BalanceEnvelope.self, from: data)
        } catch {
            throw ZenMuxUsageError.parseFailed(error.localizedDescription)
        }
        guard response.success else {
            throw ZenMuxUsageError.parseFailed("balance response reported failure")
        }
        guard response.data.currency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "usd" else {
            throw ZenMuxUsageError.parseFailed("balance currency is not USD")
        }
        return response.data.totalCredits
    }

    fileprivate static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

private struct SubscriptionEnvelope: Decodable {
    struct DataPayload: Decodable {
        struct Plan: Decodable {
            let tier: String
            let expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case tier
                case expiresAt = "expires_at"
            }
        }

        struct Quota: Decodable {
            let usagePercentage: Double
            let resetsAt: String?
            let maxFlows: Double
            let usedFlows: Double
            let remainingFlows: Double

            enum CodingKeys: String, CodingKey {
                case usagePercentage = "usage_percentage"
                case resetsAt = "resets_at"
                case maxFlows = "max_flows"
                case usedFlows = "used_flows"
                case remainingFlows = "remaining_flows"
            }

            func snapshot() -> ZenMuxUsageSnapshot.QuotaWindow {
                ZenMuxUsageSnapshot.QuotaWindow(
                    usageFraction: self.usagePercentage,
                    resetsAt: ZenMuxUsageFetcher.date(self.resetsAt),
                    maxFlows: self.maxFlows,
                    usedFlows: self.usedFlows,
                    remainingFlows: self.remainingFlows)
            }
        }

        let plan: Plan
        let accountStatus: String
        let quota5Hour: Quota
        let quota7Day: Quota

        enum CodingKeys: String, CodingKey {
            case plan
            case accountStatus = "account_status"
            case quota5Hour = "quota_5_hour"
            case quota7Day = "quota_7_day"
        }
    }

    let success: Bool
    let data: DataPayload
}

private struct BalanceEnvelope: Decodable {
    struct DataPayload: Decodable {
        let currency: String
        let totalCredits: Double

        enum CodingKeys: String, CodingKey {
            case currency
            case totalCredits = "total_credits"
        }
    }

    let success: Bool
    let data: DataPayload
}
