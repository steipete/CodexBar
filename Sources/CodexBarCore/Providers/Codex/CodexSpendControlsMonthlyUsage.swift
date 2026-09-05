import Foundation

public struct CodexSpendControlsMonthlyUsageResponse: Decodable, Sendable {
    private static let inactiveEnforcementModes: Set<String> = ["none", "off", "disabled", "no_limit"]

    public let currentMonthUsage: Double?
    public let effectiveMonthlyLimit: EffectiveMonthlyLimit?
    private let currentMonthUsageWasUnmappable: Bool

    enum CodingKeys: String, CodingKey {
        case currentMonthUsage = "current_month_usage"
        case effectiveMonthlyLimit = "effective_monthly_limit"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedUsage = Self.decodeFlexibleDoubleResult(container, forKey: .currentMonthUsage)
        self.currentMonthUsage = decodedUsage.value
        self.currentMonthUsageWasUnmappable = decodedUsage.unmappable
        self.effectiveMonthlyLimit = try container.decodeIfPresent(
            EffectiveMonthlyLimit.self,
            forKey: .effectiveMonthlyLimit)
    }

    public var monthlyLimitMappingFailed: Bool {
        let mappedLimit = self.effectiveMonthlyLimit?.limit
        let limitWasUnmappable = self.effectiveMonthlyLimit?.limitWasUnmappable == true
        if !limitWasUnmappable, (mappedLimit ?? 0) <= 0 {
            return false
        }
        if self.effectiveMonthlyLimit?.enforcementModeWasUnmappable == true { return true }
        if self.hasInactiveEnforcement { return false }
        if limitWasUnmappable { return true }
        guard mappedLimit ?? 0 > 0 else { return false }
        return self.currentMonthUsageWasUnmappable
    }

    private var hasInactiveEnforcement: Bool {
        guard let mode = self.effectiveMonthlyLimit?.enforcementMode?.lowercased() else { return false }
        return Self.inactiveEnforcementModes.contains(mode)
    }

    public func codexCreditLimitSnapshot(updatedAt: Date) -> CodexCreditLimitSnapshot? {
        guard let limit = self.effectiveMonthlyLimit?.limit, limit > 0 else { return nil }
        if self.hasInactiveEnforcement {
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
        public let limitWasUnmappable: Bool
        public let enforcementMode: String?
        public let enforcementModeWasUnmappable: Bool
        public let limitMode: String?

        enum CodingKeys: String, CodingKey {
            case limit
            case enforcementMode = "enforcement_mode"
            case limitMode = "limit_mode"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedLimit = CodexSpendControlsMonthlyUsageResponse.decodeFlexibleDoubleResult(
                container,
                forKey: .limit)
            self.limit = decodedLimit.value
            self.limitWasUnmappable = decodedLimit.unmappable
            let decodedMode = CodexSpendControlsMonthlyUsageResponse.decodeOptionalStringResult(
                container,
                forKey: .enforcementMode)
            self.enforcementMode = decodedMode.value
            self.enforcementModeWasUnmappable = decodedMode.unmappable
            self.limitMode = try? container.decodeIfPresent(String.self, forKey: .limitMode)
        }
    }

    private static func decodeFlexibleDouble<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> Double?
    {
        self.decodeFlexibleDoubleResult(container, forKey: key).value
    }

    fileprivate static func decodeFlexibleDoubleResult<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> (value: Double?, unmappable: Bool)
    {
        guard container.contains(key) else { return (nil, false) }
        if (try? container.decodeNil(forKey: key)) == true {
            return (nil, false)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return self.mappedFiniteDouble(value)
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Self.mappedFiniteDouble(Double(value))
        }
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Double(trimmed) {
                return Self.mappedFiniteDouble(parsed)
            }
            return (nil, true)
        }
        return (nil, true)
    }

    private static func mappedFiniteDouble(_ value: Double) -> (value: Double?, unmappable: Bool) {
        guard value.isFinite else { return (nil, true) }
        return (value, false)
    }

    fileprivate static func decodeOptionalStringResult<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> (value: String?, unmappable: Bool)
    {
        guard container.contains(key) else { return (nil, false) }
        if (try? container.decodeNil(forKey: key)) == true {
            return (nil, false)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return (value, false)
        }
        return (nil, true)
    }
}

enum CodexSpendControlsMonthlyUsageGate {
    static func shouldFetch(response: CodexUsageResponse) -> Bool {
        guard response.resolvedIndividualLimit?.codexCreditLimitSnapshot(updatedAt: Date()) == nil,
              response.spendControlPresent
        else { return false }

        return switch response.planType {
        case .guest, .free, .go, .plus, .pro:
            false
        case .team, .business, .education, .quorum, .k12, .enterprise, .edu, .freeWorkspace, .unknown, nil:
            true
        }
    }
}
