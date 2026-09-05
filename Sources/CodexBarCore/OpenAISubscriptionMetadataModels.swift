import Foundation

public struct OpenAISubscriptionMetadata: Equatable, Sendable {
    public let expiresAt: Date?
    public let renewsAt: Date?

    public init(expiresAt: Date?, renewsAt: Date?) {
        self.expiresAt = expiresAt
        self.renewsAt = renewsAt
    }

    static func parse(activeUntil: String?, willRenew: Bool?) -> Self? {
        guard let activeUntil,
              let willRenew,
              let date = self.parseISO8601(activeUntil)
        else { return nil }

        return willRenew
            ? Self(expiresAt: nil, renewsAt: date)
            : Self(expiresAt: date, renewsAt: nil)
    }

    static func parseResult(
        activeUntil: String?,
        willRenew: Bool?,
        fieldsPresent: Bool = true) -> OpenAISubscriptionFetchResult
    {
        guard fieldsPresent else { return .unavailable }
        guard let activeUntil else {
            return willRenew == true ? .unavailable : .success(nil)
        }
        guard let metadata = self.parse(activeUntil: activeUntil, willRenew: willRenew) else {
            return .unavailable
        }
        return .success(metadata)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public enum OpenAISubscriptionFetchResult: Equatable, Sendable {
    case unavailable
    case success(OpenAISubscriptionMetadata?)

    public var metadata: OpenAISubscriptionMetadata? {
        guard case let .success(metadata) = self else { return nil }
        return metadata
    }

    public var succeeded: Bool {
        if case .success = self { return true }
        return false
    }
}
