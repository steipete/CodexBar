import Foundation

/// Billing/customer payload opencode.ai returns for a Zen workspace.
///
/// Pay-as-you-go workspaces have no subscription object, so usage lives in `monthlyUsage` /
/// `monthlyLimit` / `balance` instead of the retired `rollingUsage.usagePercent` shape.
struct OpenCodeZenBillingInfo: Equatable, Sendable {
    /// Spend in the current monthly cycle, in USD.
    let monthlyUsageUSD: Double
    /// Configured monthly spend limit, in USD. `nil` when the workspace has no limit set.
    let monthlyLimitUSD: Double?
    /// Remaining prepaid balance, in USD.
    let balanceUSD: Double?
    /// Whether the workspace still carries a subscription object (legacy quota accounts).
    let hasSubscription: Bool
    /// When opencode.ai last recomputed `monthlyUsage`.
    let usageUpdatedAt: Date?
}

enum OpenCodeZenBillingParser {
    /// opencode.ai reports `balance` and `monthlyUsage` as fixed-point integers scaled by 1e8,
    /// while `monthlyLimit`/`reloadAmount`/`reloadTrigger` are already whole USD.
    /// `OpenCodeGoZenBalanceParser` uses the same divisor for the Zen balance it renders today.
    static let usdScale = 100_000_000.0

    /// Parses the customer/billing payload returned by the billing server function.
    ///
    /// The response arrives as SolidStart's `$R[...]` JavaScript payload rather than JSON, so the
    /// JSON path is tried first and a tolerant field scan is used as fallback. `customerID` must be
    /// present before any number is trusted, so unrelated payloads never yield a bogus snapshot.
    static func parse(text: String) -> OpenCodeZenBillingInfo? {
        if let info = self.parseJSON(text: text) {
            return info
        }
        return self.parsePayload(text: text)
    }

    private static func parseJSON(text: String) -> OpenCodeZenBillingInfo? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let customer = self.findCustomerDictionary(in: object)
        else {
            return nil
        }
        guard let rawUsage = self.doubleValue(from: customer["monthlyUsage"]) else { return nil }
        return OpenCodeZenBillingInfo(
            monthlyUsageUSD: rawUsage / self.usdScale,
            monthlyLimitUSD: self.doubleValue(from: customer["monthlyLimit"]),
            balanceUSD: self.doubleValue(from: customer["balance"]).map { $0 / self.usdScale },
            hasSubscription: !(customer["subscription"] is NSNull) && customer["subscription"] != nil,
            usageUpdatedAt: self.dateValue(from: customer["timeMonthlyUsageUpdated"]))
    }

    private static func parsePayload(text: String) -> OpenCodeZenBillingInfo? {
        guard self.containsMatch(pattern: self.fieldPattern(for: "customerID", value: #"\"[^\"]+\""#), text: text),
              let rawUsage = self.number(field: "monthlyUsage", text: text)
        else {
            return nil
        }
        return OpenCodeZenBillingInfo(
            monthlyUsageUSD: rawUsage / self.usdScale,
            monthlyLimitUSD: self.number(field: "monthlyLimit", text: text),
            balanceUSD: self.number(field: "balance", text: text).map { $0 / self.usdScale },
            hasSubscription: self.hasSubscriptionObject(text: text),
            usageUpdatedAt: self.payloadDate(field: "timeMonthlyUsageUpdated", text: text))
    }

    /// A subscription is only considered present when the field exists and is not `null`, so a
    /// pay-as-you-go payload never routes back into the retired subscription path.
    private static func hasSubscriptionObject(text: String) -> Bool {
        guard self.containsMatch(pattern: self.fieldPattern(for: "subscription", value: #"[^,}]+"#), text: text) else {
            return false
        }
        return !self.containsMatch(pattern: self.fieldPattern(for: "subscription", value: "null"), text: text)
    }

    private static func findCustomerDictionary(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let customerID = dict["customerID"] as? String, !customerID.isEmpty {
                return dict
            }
            for value in dict.values {
                if let found = self.findCustomerDictionary(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = self.findCustomerDictionary(in: value) {
                    return found
                }
            }
        }
        return nil
    }

    /// Matches both JSON (`"balance": 1`) and the `$R[...]` payload (`balance:$R[3]=1`).
    private static func fieldPattern(for field: String, value: String) -> String {
        #"(?:\""# + field + #"\"|"# + field + #")\s*:\s*(?:\$R\[\d+\]\s*=\s*)?"# + value
    }

    private static func number(field: String, text: String) -> Double? {
        self.firstCapture(
            pattern: self.fieldPattern(for: field, value: #"(-?[0-9]+(?:\.[0-9]+)?)"#),
            text: text)
            .flatMap(Double.init)
    }

    private static func payloadDate(field: String, text: String) -> Date? {
        let value = #"(?:new\s+Date\(\s*)?\"([^\"]+)\""#
        guard let raw = self.firstCapture(pattern: self.fieldPattern(for: field, value: value), text: text) else {
            return nil
        }
        return self.dateValue(from: raw)
    }

    private static func firstCapture(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private static func containsMatch(pattern: String, text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: nsrange) != nil
    }

    private static func doubleValue(from value: Any?) -> Double? {
        let number: Double? = switch value {
        case is Bool:
            nil
        case let number as Double:
            number
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func dateValue(from value: Any?) -> Date? {
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) {
                return parsed
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }
        if let number = self.doubleValue(from: value) {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        return nil
    }
}
