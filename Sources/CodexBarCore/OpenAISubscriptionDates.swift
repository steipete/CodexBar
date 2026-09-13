import Foundation

/// Renewal/expiry dates from ChatGPT's subscriptions payload.
/// Kept independent of WebKit so OAuth usage can attach subscription metadata without browser access.
public struct OpenAISubscriptionDates: Equatable, Sendable {
    public let expiresAt: Date?
    public let renewsAt: Date?

    public init(expiresAt: Date?, renewsAt: Date?) {
        self.expiresAt = expiresAt
        self.renewsAt = renewsAt
    }

    public static func parse(data: Data) -> Self? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activeUntil = json["active_until"] as? String ?? json["activeUntil"] as? String,
              let willRenew = json["will_renew"] as? Bool ?? json["willRenew"] as? Bool,
              let periodEnd = self.parseDate(activeUntil)
        else { return nil }

        return willRenew
            ? Self(expiresAt: nil, renewsAt: periodEnd)
            : Self(expiresAt: periodEnd, renewsAt: nil)
    }

    static func responseShape(data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return "non-json" }
        if let object = json as? [String: Any] {
            return object.keys.sorted().prefix(20).joined(separator: ",")
        }
        if let items = json as? [Any] {
            return "array(count=\(items.count))"
        }
        return String(describing: type(of: json))
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
