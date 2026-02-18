import Foundation

public struct CopilotUsageResponse: Sendable, Decodable {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public struct QuotaSnapshot: Sendable, Decodable {
        public let entitlement: Double
        public let remaining: Double
        public let percentRemaining: Double
        public let quotaId: String
        public var isPlaceholder: Bool {
            self.entitlement == 0 && self.remaining == 0 && self.percentRemaining == 0 && self.quotaId.isEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case entitlement
            case remaining
            case percentRemaining = "percent_remaining"
            case quotaId = "quota_id"
        }

        public init(
            entitlement: Double,
            remaining: Double,
            percentRemaining: Double,
            quotaId: String)
        {
            self.entitlement = entitlement
            self.remaining = remaining
            self.percentRemaining = percentRemaining
            self.quotaId = quotaId
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.entitlement = try container.decodeIfPresent(Double.self, forKey: .entitlement) ?? 0
            self.remaining = try container.decodeIfPresent(Double.self, forKey: .remaining) ?? 0
            self.percentRemaining = try container.decodeIfPresent(Double.self, forKey: .percentRemaining) ?? 0
            self.quotaId = try container.decodeIfPresent(String.self, forKey: .quotaId) ?? ""
        }
    }

    public struct QuotaCounts: Sendable, Decodable {
        public let chat: Double?
        public let completions: Double?

        private enum CodingKeys: String, CodingKey {
            case chat
            case completions
        }

        public init(chat: Double?, completions: Double?) {
            self.chat = chat
            self.completions = completions
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.chat = Self.decodeNumberIfPresent(container: container, key: .chat)
            self.completions = Self.decodeNumberIfPresent(container: container, key: .completions)
        }

        private static func decodeNumberIfPresent(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys) -> Double?
        {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(value)
            }
            return nil
        }
    }

    public struct QuotaSnapshots: Sendable, Decodable {
        public let premiumInteractions: QuotaSnapshot?
        public let chat: QuotaSnapshot?

        private enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
        }

        public init(premiumInteractions: QuotaSnapshot?, chat: QuotaSnapshot?) {
            self.premiumInteractions = premiumInteractions
            self.chat = chat
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var premium = try container.decodeIfPresent(QuotaSnapshot.self, forKey: .premiumInteractions)
            var chat = try container.decodeIfPresent(QuotaSnapshot.self, forKey: .chat)

            if premium == nil || chat == nil {
                let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
                var fallbackPremium: QuotaSnapshot?
                var fallbackChat: QuotaSnapshot?
                var firstUsable: QuotaSnapshot?

                for key in dynamic.allKeys {
                    let value: QuotaSnapshot
                    do {
                        guard let decoded = try dynamic.decodeIfPresent(QuotaSnapshot.self, forKey: key) else {
                            continue
                        }
                        guard !decoded.isPlaceholder else { continue }
                        value = decoded
                    } catch {
                        continue
                    }

                    let name = key.stringValue.lowercased()
                    if firstUsable == nil {
                        firstUsable = value
                    }

                    if fallbackChat == nil, name.contains("chat") {
                        fallbackChat = value
                        continue
                    }

                    if fallbackPremium == nil,
                       name.contains("premium") || name.contains("completion") || name.contains("code")
                    {
                        fallbackPremium = value
                    }
                }

                if premium == nil {
                    premium = fallbackPremium
                }
                if chat == nil {
                    chat = fallbackChat
                }
                if premium == nil, chat == nil {
                    // If keys are unfamiliar, still expose one usable quota instead of failing.
                    chat = firstUsable
                }
            }

            self.premiumInteractions = premium
            self.chat = chat
        }
    }

    public let quotaSnapshots: QuotaSnapshots
    public let copilotPlan: String
    public let assignedDate: String
    public let quotaResetDate: String

    private enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case assignedDate = "assigned_date"
        case quotaResetDate = "quota_reset_date"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }

    public init(
        quotaSnapshots: QuotaSnapshots,
        copilotPlan: String,
        assignedDate: String?,
        quotaResetDate: String?)
    {
        self.quotaSnapshots = quotaSnapshots
        self.copilotPlan = copilotPlan
        self.assignedDate = assignedDate
        self.quotaResetDate = quotaResetDate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directSnapshots = try container.decodeIfPresent(QuotaSnapshots.self, forKey: .quotaSnapshots)
        let monthlyQuotas = try container.decodeIfPresent(QuotaCounts.self, forKey: .monthlyQuotas)
        let limitedUserQuotas = try container.decodeIfPresent(QuotaCounts.self, forKey: .limitedUserQuotas)
        let monthlyLimitedSnapshots = Self.makeQuotaSnapshots(monthly: monthlyQuotas, limited: limitedUserQuotas)
        if let directSnapshots, Self.hasUsableQuota(in: directSnapshots) {
            self.quotaSnapshots = directSnapshots
        } else if let monthlyLimitedSnapshots {
            self.quotaSnapshots = monthlyLimitedSnapshots
        } else {
            self.quotaSnapshots = directSnapshots ?? QuotaSnapshots(premiumInteractions: nil, chat: nil)
        }
        self.copilotPlan = try container.decodeIfPresent(String.self, forKey: .copilotPlan) ?? "unknown"
        self.assignedDate = try container.decodeIfPresent(String.self, forKey: .assignedDate) ?? ""
        self.quotaResetDate = try container.decodeIfPresent(String.self, forKey: .quotaResetDate) ?? ""
    }

    private static func makeQuotaSnapshots(monthly: QuotaCounts?, limited: QuotaCounts?) -> QuotaSnapshots? {
        let premium = Self.makeQuotaSnapshot(
            monthly: monthly?.completions,
            limited: limited?.completions,
            quotaID: "completions")
        let chat = Self.makeQuotaSnapshot(
            monthly: monthly?.chat,
            limited: limited?.chat,
            quotaID: "chat")
        guard premium != nil || chat != nil else { return nil }
        return QuotaSnapshots(premiumInteractions: premium, chat: chat)
    }

    private static func makeQuotaSnapshot(monthly: Double?, limited: Double?, quotaID: String) -> QuotaSnapshot? {
        guard monthly != nil || limited != nil else { return nil }

        let entitlement = max(0, monthly ?? 0)
        let remaining = max(0, limited ?? monthly ?? 0)
        let percentRemaining: Double = if entitlement > 0 {
            max(0, min(100, (remaining / entitlement) * 100))
        } else {
            0
        }

        return QuotaSnapshot(
            entitlement: entitlement,
            remaining: remaining,
            percentRemaining: percentRemaining,
            quotaId: quotaID)
    }

    private static func hasUsableQuota(in snapshots: QuotaSnapshots) -> Bool {
        if let premium = snapshots.premiumInteractions, !premium.isPlaceholder {
            return true
        }
        if let chat = snapshots.chat, !chat.isPlaceholder {
            return true
        }
        return false
    }
}
