import Foundation
import Testing
@testable import CodexBarCore

struct TraeCNProviderTests {
    private static let sampleResponse = """
    {
        "is_credits_billing": true,
        "is_dollar_usage_billing": false,
        "trial_status": { "is_eligible_for_trial": false, "is_in_trial": false },
        "usage_summary": {
            "consumed_amount": 6958.35,
            "consumption_ratio": 0.3614727272727273,
            "total_amount": 19250
        },
        "user_entitlement_pack_list": [
            {
                "display_desc": "会员 Pro+ 连续包月",
                "group_name": "会员积分",
                "group_type": 0,
                "expire_time": 1792567945,
                "next_billing_time": 1792500600,
                "status": 1,
                "usage": { "credits_amount": 2808.3488 }
            },
            {
                "display_desc": "老用户福利",
                "group_name": "用户福利",
                "group_type": 4,
                "expire_time": 1792565071,
                "next_billing_time": 0,
                "status": 0,
                "usage": { "credits_amount": 2000 }
            }
        ]
    }
    """

    @Test
    func parseEntitlementSnapshotReadsUsageSummary() throws {
        let now = Date(timeIntervalSince1970: 1_792_477_633)
        let snapshot = try TraeCNUsageFetcher.parseEntitlementSnapshot(
            from: Data(Self.sampleResponse.utf8),
            now: now)

        #expect(snapshot.creditsLimit == 19250)
        #expect(snapshot.creditsUsed == 6958.35)
        #expect(snapshot.creditsRemaining == 19250 - 6958.35)
        #expect(snapshot.planCode == "会员 Pro+ 连续包月")
        #expect(snapshot.planPeriodEnd == Date(timeIntervalSince1970: 1_792_567_945))
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func parseEntitlementSnapshotFallsBackToNextBillingTime() throws {
        let json = """
        {
            "usage_summary": { "consumed_amount": 100, "total_amount": 1000 },
            "user_entitlement_pack_list": [
                { "display_desc": "会员 Pro", "group_type": 0, "expire_time": 0, "next_billing_time": 1792500600 }
            ]
        }
        """
        let snapshot = try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data(json.utf8))
        #expect(snapshot.planPeriodEnd == Date(timeIntervalSince1970: 1_792_500_600))
    }

    @Test
    func parseEntitlementSnapshotWithoutSubscriptionPackHasNoReset() throws {
        let json = """
        {
            "usage_summary": { "consumed_amount": 100, "total_amount": 1000 },
            "user_entitlement_pack_list": [
                { "display_desc": "福利积分", "group_type": 4, "expire_time": 1792567945 }
            ]
        }
        """
        let snapshot = try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data(json.utf8))
        #expect(snapshot.planPeriodEnd == nil)
        #expect(snapshot.planCode == nil)
    }

    @Test
    func parseEntitlementSnapshotRejectsMissingSummary() {
        let json = #"{"user_entitlement_pack_list": []}"#
        #expect(throws: TraeCNUsageError.self) {
            try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func parseEntitlementSnapshotRejectsGarbage() {
        #expect(throws: TraeCNUsageError.self) {
            try TraeCNUsageFetcher.parseEntitlementSnapshot(from: Data("not json".utf8))
        }
    }

    @Test
    func jwtExpiryDateReadsExpClaim() {
        // payload {"exp": 1792507401, "iat": 1792478601}
        let payload = Data(#"{"exp":1792507401,"iat":1792478601}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let jwt = "header.\(payload).signature"
        #expect(TraeCNUsageFetcher.jwtExpiryDate(jwt) == Date(timeIntervalSince1970: 1_792_507_401))
    }

    @Test
    func jwtExpiryDateRejectsGarbage() {
        #expect(TraeCNUsageFetcher.jwtExpiryDate("not-a-jwt") == nil)
    }

    @Test
    func toUsageSnapshotMapsCreditsWindowAndDetails() throws {
        let now = Date(timeIntervalSince1970: 1_792_477_633)
        let periodEnd = Date(timeIntervalSince1970: 1_792_500_600)
        let snapshot = TraeCNUsageSnapshot(
            creditsUsed: 6958.35,
            creditsLimit: 19250,
            creditsRemaining: 12291.65,
            planCode: "会员 Pro+ 连续包月",
            planPeriodEnd: periodEnd,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(primary.usedPercent > 36.1 && primary.usedPercent < 36.2)
        #expect(primary.resetsAt == periodEnd)
        #expect(primary.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.identity?.loginMethod == "会员 Pro+ 连续包月")
        #expect(usage.detailRow(label: "Remaining") != nil)
    }
}
