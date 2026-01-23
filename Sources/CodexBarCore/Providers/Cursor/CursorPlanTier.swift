import Foundation

/// Represents Cursor subscription plan tiers with their effective usage budgets.
///
/// Higher-tier plans provide more effective capacity than their nominal price suggests.
/// For example, Ultra ($200/mo) provides approximately 20x the value of a baseline Pro plan,
/// meaning users can consume ~$800 worth of API usage before hitting limits.
public enum CursorPlanTier: String, Codable, Sendable {
    case hobby
    case pro
    case proPlus
    case ultra
    case team
    case enterprise
    case unknown

    /// Initialize plan tier from the API's membership type string.
    /// - Parameter membershipType: The membership type from Cursor's API (e.g., "pro", "pro+", "ultra")
    public init(membershipType: String?) {
        switch membershipType?.lowercased() {
        case "hobby":
            self = .hobby
        case "pro":
            self = .pro
        case "pro+", "pro_plus", "proplus":
            self = .proPlus
        case "ultra":
            self = .ultra
        case "team":
            self = .team
        case "enterprise":
            self = .enterprise
        default:
            self = .unknown
        }
    }

    /// Effective budget in USD based on plan tier.
    ///
    /// These values approximate the actual usage capacity provided by each tier,
    /// calibrated against a ~$40 Pro baseline:
    /// - Pro ($20/mo) provides ~$40 effective (1x baseline)
    /// - Pro+ ($60/mo) provides ~$120 effective (3x baseline)
    /// - Ultra ($200/mo) provides ~$800 effective (20x baseline)
    public var effectiveBudgetUSD: Double {
        switch self {
        case .hobby:
            return 20
        case .pro:
            return 40
        case .proPlus:
            return 120 // 3x baseline
        case .ultra:
            return 800 // 20x baseline
        case .team:
            return 60
        case .enterprise, .unknown:
            return 40 // Conservative default
        }
    }

    /// Display name for the plan tier.
    public var displayName: String {
        switch self {
        case .hobby:
            return "Hobby"
        case .pro:
            return "Pro"
        case .proPlus:
            return "Pro+"
        case .ultra:
            return "Ultra"
        case .team:
            return "Team"
        case .enterprise:
            return "Enterprise"
        case .unknown:
            return "Unknown"
        }
    }
}
