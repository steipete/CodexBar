import Foundation

public struct CodexSpendControlsMonthlyUsageResponse: Decodable, Sendable {
    public let currentMonthUsage: Double?
    public let effectiveMonthlyLimit: EffectiveMonthlyLimit?

    enum CodingKeys: String, CodingKey {
        case currentMonthUsage = "current_month_usage"
        case effectiveMonthlyLimit = "effective_monthly_limit"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentMonthUsage = Self.decodeFlexibleDouble(container, forKey: .currentMonthUsage)
        self.effectiveMonthlyLimit = try? container.decodeIfPresent(
            EffectiveMonthlyLimit.self,
            forKey: .effectiveMonthlyLimit)
    }

    public func codexCreditLimitSnapshot(updatedAt: Date) -> CodexCreditLimitSnapshot? {
        guard let limit = self.effectiveMonthlyLimit?.limit, limit > 0 else { return nil }
        if let enforcementMode = self.effectiveMonthlyLimit?.enforcementMode?.lowercased(),
           ["none", "off", "disabled", "no_limit"].contains(enforcementMode)
        {
            return nil
        }

        let used = max(0, self.currentMonthUsage ?? 0)
        let remainingPercent = max(0, min(100, 100 - (used / limit * 100)))
        return CodexCreditLimitSnapshot(
            used: used,
            limit: limit,
            remainingPercent: remainingPercent,
            resetsAt: nil,
            updatedAt: updatedAt)
    }

    public struct EffectiveMonthlyLimit: Decodable, Sendable {
        public let limit: Double?
        public let enforcementMode: String?
        public let limitMode: String?

        enum CodingKeys: String, CodingKey {
            case limit
            case enforcementMode = "enforcement_mode"
            case limitMode = "limit_mode"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.limit = CodexSpendControlsMonthlyUsageResponse.decodeFlexibleDouble(container, forKey: .limit)
            self.enforcementMode = try? container.decodeIfPresent(String.self, forKey: .enforcementMode)
            self.limitMode = try? container.decodeIfPresent(String.self, forKey: .limitMode)
        }
    }

    private static func decodeFlexibleDouble<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> Double?
    {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

enum CodexSpendControlsMonthlyUsageGate {
    static func shouldFetch(response: CodexUsageResponse) -> Bool {
        guard response.resolvedIndividualLimit?.codexCreditLimitSnapshot(updatedAt: Date()) == nil,
              response.spendControlPresent
        else { return false }

        return switch response.planType {
        case .team, .business, .education, .quorum, .k12, .enterprise, .edu, .freeWorkspace:
            true
        case .guest, .free, .go, .plus, .pro, .unknown, nil:
            false
        }
    }
}
