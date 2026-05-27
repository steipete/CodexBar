import Foundation

public enum ProviderSubscriptionReminderType: String, Hashable, Sendable, Codable {
    case renewsIn30Days
    case renewsIn7Days
    case renewsIn3Days
    case renewsIn1Day
    case renewsToday
    case expiresIn30Days
    case expiresIn7Days
    case expiresIn3Days
    case expiresIn1Day
    case expiresToday
    case expired
}

public struct ProviderSubscriptionReminderState: Equatable, Sendable, Codable {
    public let fingerprint: String
    public var fired: Set<ProviderSubscriptionReminderType>

    public init(fingerprint: String, fired: Set<ProviderSubscriptionReminderType>) {
        self.fingerprint = fingerprint
        self.fired = fired
    }
}
