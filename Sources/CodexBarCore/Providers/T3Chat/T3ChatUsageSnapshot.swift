import Foundation

public enum T3ChatUsageError: LocalizedError, Sendable {
    case noSessionCookie
    case invalidCredentials
    case vercelChallenge
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No T3 Chat cookies found. Please log in to t3.chat in your browser."
        case .invalidCredentials:
            "T3 Chat session cookie is invalid or expired."
        case .vercelChallenge:
            "T3 Chat returned a Vercel security challenge. Paste the full browser cURL request, " +
                "not just the Cookie header."
        case let .apiError(message):
            "T3 Chat API error: \(message)"
        case let .parseFailed(message):
            "Could not parse T3 Chat usage: \(message)"
        }
    }
}

public struct T3ChatSubscription: Decodable, Sendable {
    public let productId: String?
    public let productName: String?
    public let status: String?
    public let currentPeriodStart: TimeInterval?
    public let currentPeriodEnd: TimeInterval?
    public let canceledAt: TimeInterval?
    public let trialEndsAt: TimeInterval?
}

public struct T3ChatCustomerData: Decodable, Sendable {
    public let subTier: String?
    public let subscription: T3ChatSubscription?
    public let lifetimeBalance: Double?
    public let usageBand: String?
    public let billingNextResetAt: TimeInterval?
    public let usageFourHourPercentage: Double?
    public let usageMonthPercentage: Double?
    public let usageFourHourNextResetAt: TimeInterval?
    public let usagePeriodPercentage: Double?
    public let usageWindowNextResetAt: TimeInterval?

    public var planName: String? {
        let raw = self.subscription?.productName ?? self.subTier
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.split(separator: "-").map { part in
            part.prefix(1).uppercased() + String(part.dropFirst())
        }.joined(separator: " ")
    }
}

public struct T3ChatUsageSnapshot: Sendable {
    public let customerData: T3ChatCustomerData
    public let updatedAt: Date

    public init(customerData: T3ChatCustomerData, updatedAt: Date) {
        self.customerData = customerData
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let baseReset = Self.date(fromMilliseconds: self.customerData.usageFourHourNextResetAt)
            ?? Self.date(fromMilliseconds: self.customerData.usageWindowNextResetAt)
        // billingNextResetAt tracks the usage window reset, not the overage billing period.
        // If subscription metadata is absent, leave the overage reset unknown instead of showing the base reset.
        let overageReset = Self.date(fromMilliseconds: self.customerData.subscription?.currentPeriodEnd)

        let primary = RateWindow(
            usedPercent: Self.percent(self.customerData.usageFourHourPercentage),
            windowMinutes: 4 * 60,
            resetsAt: baseReset,
            resetDescription: Self.description(label: "Base", usageBand: self.customerData.usageBand))

        let secondaryPercent = self.customerData.usageMonthPercentage
            ?? self.customerData.usagePeriodPercentage
        let secondary = RateWindow(
            usedPercent: Self.percent(secondaryPercent),
            windowMinutes: nil,
            resetsAt: overageReset,
            resetDescription: "Overage")

        let identity = ProviderIdentitySnapshot(
            providerID: .t3chat,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.customerData.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func percent(_ raw: Double?) -> Double {
        min(100, max(0, raw ?? 0))
    }

    private static func date(fromMilliseconds raw: TimeInterval?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        // T3 Chat currently returns JavaScript epoch milliseconds, while some subscription fields may be seconds.
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func description(label: String, usageBand: String?) -> String {
        guard let usageBand = usageBand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !usageBand.isEmpty
        else {
            return label
        }
        return "\(label) - \(usageBand)"
    }
}

public enum T3ChatUsageParser {
    public static func parseJSONLines(_ data: Data, now: Date = Date()) throws -> T3ChatUsageSnapshot {
        guard let text = String(data: data, encoding: .utf8) else {
            throw T3ChatUsageError.parseFailed("Response is not UTF-8.")
        }
        return try self.parseJSONLines(text, now: now)
    }

    public static func parseJSONLines(_ text: String, now: Date = Date()) throws -> T3ChatUsageSnapshot {
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = String(line).data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            guard let customerObject = self.findCustomerData(in: object) else { continue }
            let customerData = try self.decodeCustomerData(customerObject)
            return T3ChatUsageSnapshot(customerData: customerData, updatedAt: now)
        }

        throw T3ChatUsageError.parseFailed("Missing customer data object.")
    }

    private static func findCustomerData(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if dictionary["usageFourHourPercentage"] != nil ||
                dictionary["usageMonthPercentage"] != nil ||
                dictionary["subscription"] != nil && dictionary["usageBand"] != nil
            {
                return dictionary
            }

            for value in dictionary.values {
                if let found = self.findCustomerData(in: value) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findCustomerData(in: value) {
                    return found
                }
            }
        }

        return nil
    }

    private static func decodeCustomerData(_ object: [String: Any]) throws -> T3ChatCustomerData {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return try JSONDecoder().decode(T3ChatCustomerData.self, from: data)
        } catch {
            throw T3ChatUsageError.parseFailed(error.localizedDescription)
        }
    }
}
