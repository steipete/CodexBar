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
        public let creditsUsed: Double?
        public let percentRemaining: Double
        public let quotaId: String
        public let hasPercentRemaining: Bool
        public let unlimited: Bool
        private let entitlementWasDecoded: Bool
        private let remainingWasDecoded: Bool
        public var usedPercent: Double {
            max(0, 100 - self.percentRemaining)
        }

        public var overQuotaUsedPercent: Double? {
            self.usedPercent > 100 ? self.usedPercent : nil
        }

        public var isPlaceholder: Bool {
            if self.unlimited {
                return false
            }

            if self.entitlement == 0,
               self.remaining == 0,
               self.percentRemaining == 0,
               !self.hasPercentRemaining
            {
                return true
            }

            // An explicit zero-entitlement, zero-remaining snapshot carries no usable quota signal.
            // GitHub returns this shape for token-based billing / Copilot Business seats,
            // sometimes as percent_remaining=100 with a non-empty quota_id, which would
            // otherwise render as a misleading "0% used" (100 - 100). Treat it as a
            // placeholder so the usual handling drops it instead of showing fake usage.
            return self.entitlementWasDecoded && self.remainingWasDecoded && self.entitlement == 0 && self
                .remaining == 0
        }

        /// Whether the snapshot carries a real absolute credit counter, even when
        /// it lacks a usable percentage window. Such snapshots stay accessible in
        /// the decoded response without ever becoming a fake percentage bar.
        public var carriesCreditsCounter: Bool {
            self.creditsUsed != nil
        }

        private enum CodingKeys: String, CodingKey {
            case entitlement
            case remaining
            case creditsUsed = "credits_used"
            case percentRemaining = "percent_remaining"
            case quotaId = "quota_id"
            case unlimited
        }

        public init(
            entitlement: Double,
            remaining: Double,
            percentRemaining: Double,
            quotaId: String,
            creditsUsed: Double? = nil,
            hasPercentRemaining: Bool = true,
            unlimited: Bool = false)
        {
            self.entitlement = entitlement
            self.remaining = remaining
            self.creditsUsed = creditsUsed
            self.percentRemaining = unlimited ? 100 : percentRemaining
            self.quotaId = quotaId
            self.hasPercentRemaining = unlimited || hasPercentRemaining
            self.unlimited = unlimited
            self.entitlementWasDecoded = true
            self.remainingWasDecoded = true
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedEntitlement = Self.decodeNumberIfPresent(container: container, key: .entitlement)
            let decodedRemaining = Self.decodeNumberIfPresent(container: container, key: .remaining)
            self.entitlement = decodedEntitlement ?? 0
            self.remaining = decodedRemaining ?? 0
            self.entitlementWasDecoded = decodedEntitlement != nil
            self.remainingWasDecoded = decodedRemaining != nil
            self.creditsUsed = Self.decodeNumberIfPresent(container: container, key: .creditsUsed)
            let decodedUnlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
            let decodedPercent = Self.decodeNumberIfPresent(container: container, key: .percentRemaining)
            if decodedUnlimited {
                self.percentRemaining = 100
                self.hasPercentRemaining = true
            } else if let decodedPercent {
                self.percentRemaining = decodedPercent
                self.hasPercentRemaining = true
            } else if let entitlement = decodedEntitlement,
                      entitlement > 0,
                      let remaining = decodedRemaining
            {
                let derived = (remaining / entitlement) * 100
                self.percentRemaining = derived
                self.hasPercentRemaining = true
            } else {
                // Without percent_remaining and both inputs for derivation, the percent is unknown.
                self.percentRemaining = 0
                self.hasPercentRemaining = false
            }
            self.quotaId = try container.decodeIfPresent(String.self, forKey: .quotaId) ?? ""
            self.unlimited = decodedUnlimited
        }

        private init(
            entitlement: Double,
            remaining: Double,
            creditsUsed: Double?,
            percentRemaining: Double,
            quotaId: String,
            hasPercentRemaining: Bool,
            unlimited: Bool,
            entitlementWasDecoded: Bool,
            remainingWasDecoded: Bool)
        {
            self.entitlement = entitlement
            self.remaining = remaining
            self.creditsUsed = creditsUsed
            self.percentRemaining = percentRemaining
            self.quotaId = quotaId
            self.hasPercentRemaining = hasPercentRemaining
            self.unlimited = unlimited
            self.entitlementWasDecoded = entitlementWasDecoded
            self.remainingWasDecoded = remainingWasDecoded
        }

        /// Returns a copy carrying `creditsUsed`, preserving the decoded-flag
        /// semantics that placeholder classification depends on.
        fileprivate func withCreditsUsed(_ creditsUsed: Double?) -> QuotaSnapshot {
            QuotaSnapshot(
                entitlement: self.entitlement,
                remaining: self.remaining,
                creditsUsed: creditsUsed,
                percentRemaining: self.percentRemaining,
                quotaId: self.quotaId,
                hasPercentRemaining: self.hasPercentRemaining,
                unlimited: self.unlimited,
                entitlementWasDecoded: self.entitlementWasDecoded,
                remainingWasDecoded: self.remainingWasDecoded)
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
            if premium?.isPlaceholder == true, premium?.carriesCreditsCounter != true {
                premium = nil
            }
            if chat?.isPlaceholder == true, chat?.carriesCreditsCounter != true {
                chat = nil
            }

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
                        guard !decoded.isPlaceholder || decoded.carriesCreditsCounter else { continue }
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
    public let tokenBasedBilling: Bool
    public let assignedDate: String?
    public let quotaResetDate: String?

    private enum CodingKeys: String, CodingKey {
        case quotaSnapshots = "quota_snapshots"
        case copilotPlan = "copilot_plan"
        case tokenBasedBilling = "token_based_billing"
        case assignedDate = "assigned_date"
        case quotaResetDate = "quota_reset_date"
        case monthlyQuotas = "monthly_quotas"
        case limitedUserQuotas = "limited_user_quotas"
    }

    public init(
        quotaSnapshots: QuotaSnapshots,
        copilotPlan: String,
        tokenBasedBilling: Bool = false,
        assignedDate: String?,
        quotaResetDate: String?)
    {
        self.quotaSnapshots = quotaSnapshots
        self.copilotPlan = copilotPlan
        self.tokenBasedBilling = tokenBasedBilling
        self.assignedDate = assignedDate
        self.quotaResetDate = quotaResetDate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directSnapshots = try container.decodeIfPresent(QuotaSnapshots.self, forKey: .quotaSnapshots)
        let monthlyQuotas = try container.decodeIfPresent(QuotaCounts.self, forKey: .monthlyQuotas)
        let limitedUserQuotas = try container.decodeIfPresent(QuotaCounts.self, forKey: .limitedUserQuotas)
        let monthlyLimitedSnapshots = Self.makeQuotaSnapshots(monthly: monthlyQuotas, limited: limitedUserQuotas)
        let premium = Self.preferredQuotaSnapshot(
            direct: directSnapshots?.premiumInteractions,
            fallback: monthlyLimitedSnapshots?.premiumInteractions)
        let chat = Self.preferredQuotaSnapshot(
            direct: directSnapshots?.chat,
            fallback: monthlyLimitedSnapshots?.chat)
        if premium != nil || chat != nil {
            self.quotaSnapshots = QuotaSnapshots(premiumInteractions: premium, chat: chat)
        } else {
            self.quotaSnapshots = directSnapshots ?? QuotaSnapshots(premiumInteractions: nil, chat: nil)
        }
        self.copilotPlan = try container.decodeIfPresent(String.self, forKey: .copilotPlan) ?? "unknown"
        self.tokenBasedBilling = try container.decodeIfPresent(Bool.self, forKey: .tokenBasedBilling) ?? false
        self.assignedDate = try container.decodeIfPresent(String.self, forKey: .assignedDate)
        self.quotaResetDate = try container.decodeIfPresent(String.self, forKey: .quotaResetDate)
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
        guard let monthly else {
            // Without a monthly denominator, avoid fabricating a misleading percentage.
            return nil
        }
        guard let limited else {
            // Without the limited/remaining value, usage is unknown.
            return nil
        }

        let entitlement = max(0, monthly)
        guard entitlement > 0 else {
            // A zero denominator cannot produce a meaningful percentage.
            return nil
        }
        let remaining = max(0, limited)
        let percentRemaining = max(0, min(100, (remaining / entitlement) * 100))

        return QuotaSnapshot(
            entitlement: entitlement,
            remaining: remaining,
            percentRemaining: percentRemaining,
            quotaId: quotaID)
    }

    private static func usableQuotaSnapshot(from snapshot: QuotaSnapshot?) -> QuotaSnapshot? {
        guard let snapshot, !snapshot.isPlaceholder, snapshot.hasPercentRemaining else {
            return nil
        }
        return snapshot
    }

    private static func preferredQuotaSnapshot(
        direct: QuotaSnapshot?,
        fallback: QuotaSnapshot?) -> QuotaSnapshot?
    {
        if direct?.unlimited == true, let fallback = usableQuotaSnapshot(from: fallback) {
            // The direct snapshot's absolute credit counter is real consumption
            // even though its unlimited marker makes it ineligible for a
            // percentage window; keep the counter on the selected fallback.
            return fallback.withCreditsUsed(direct?.creditsUsed)
        }
        if let directWindow = self.usableQuotaSnapshot(from: direct) {
            return directWindow
        }
        guard let fallback = self.usableQuotaSnapshot(from: fallback) else {
            return nil
        }
        // A zero-entitlement placeholder can still carry a real absolute
        // counter; keep it on the selected fallback instead of dropping it.
        if direct?.carriesCreditsCounter == true {
            return fallback.withCreditsUsed(direct?.creditsUsed)
        }
        return fallback
    }
}
