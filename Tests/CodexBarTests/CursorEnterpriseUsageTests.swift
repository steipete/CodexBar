import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorEnterpriseUsageTests {
    @Test
    func `parses enterprise overall and pooled usage summary`() throws {
        // Live Cursor Enterprise payload (sanitized). The Pro/Hobby `plan` block is absent;
        // instead Cursor reports `individualUsage.overall` (personal cap) and `teamUsage.pooled`
        // (shared team pool). Both blocks use cents like the existing `plan` block.
        let json = """
        {
            "billingCycleStart": "2026-04-01T00:00:00.000Z",
            "billingCycleEnd": "2026-05-01T00:00:00.000Z",
            "membershipType": "enterprise",
            "limitType": "team",
            "isUnlimited": false,
            "individualUsage": {
                "overall": {
                    "enabled": true,
                    "used": 7384,
                    "limit": 10000,
                    "remaining": 2616
                }
            },
            "teamUsage": {
                "onDemand": {
                    "enabled": true,
                    "used": 0,
                    "limit": null,
                    "remaining": null
                },
                "pooled": {
                    "enabled": true,
                    "used": 12725135,
                    "limit": 28122000,
                    "remaining": 15396865
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)

        #expect(summary.membershipType == "enterprise")
        #expect(summary.limitType == "team")
        #expect(summary.individualUsage?.plan == nil)
        #expect(summary.individualUsage?.overall?.used == 7384)
        #expect(summary.individualUsage?.overall?.limit == 10000)
        #expect(summary.individualUsage?.overall?.remaining == 2616)
        #expect(summary.teamUsage?.pooled?.used == 12_725_135)
        #expect(summary.teamUsage?.pooled?.limit == 28_122_000)
    }

    @Test
    func `enterprise overall drives headline percent and dollars`() throws {
        // Regression: Cursor Enterprise/Team accounts ship `individualUsage.overall` instead of
        // `individualUsage.plan`. Without a model for `overall`, the parser used to report 0%
        // (i.e. the menu showed "100% remaining"). The personal cap must take precedence over
        // any team pool, and USD figures must reflect the same source.
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: "2026-04-01T00:00:00.000Z",
                    billingCycleEnd: "2026-05-01T00:00:00.000Z",
                    membershipType: "enterprise",
                    limitType: "team",
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: nil,
                        onDemand: nil,
                        overall: CursorOverallUsage(enabled: true, used: 7384, limit: 10000, remaining: 2616)),
                    teamUsage: CursorTeamUsage(
                        onDemand: CursorOnDemandUsage(enabled: true, used: 0, limit: nil, remaining: nil),
                        pooled: CursorPooledUsage(
                            enabled: true,
                            used: 12_725_135,
                            limit: 28_122_000,
                            remaining: 15_396_865))),
                userInfo: nil,
                rawJSON: nil)

        // Headline: $73.84 / $100 -> 73.84% (matches Cursor's own dashboard).
        // Allow a tiny tolerance for floating-point division (7384/10000 * 100).
        #expect(abs(snapshot.planPercentUsed - 73.84) < 0.0001)
        #expect(snapshot.planUsedUSD == 73.84)
        #expect(snapshot.planLimitUSD == 100.0)
        #expect(snapshot.autoPercentUsed == nil)
        #expect(snapshot.apiPercentUsed == nil)

        let primaryPercent = try #require(snapshot.toUsageSnapshot().primary?.usedPercent)
        #expect(abs(primaryPercent - 73.84) < 0.0001)
    }

    @Test
    func `enterprise pooled fallback used when no individual data`() {
        // When Cursor only reports a shared team pool (no `plan`, no `overall`) we should still surface
        // a non-zero headline so the menu reflects pool consumption rather than appearing "all clear".
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "enterprise",
                    limitType: "team",
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: nil,
                    teamUsage: CursorTeamUsage(
                        onDemand: nil,
                        pooled: CursorPooledUsage(
                            enabled: true,
                            used: 12_725_135,
                            limit: 28_122_000,
                            remaining: 15_396_865))),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed > 45.0)
        #expect(snapshot.planPercentUsed < 45.5)
        #expect(snapshot.planUsedUSD == 127_251.35)
        #expect(snapshot.planLimitUSD == 281_220.0)
    }

    @Test
    func `existing plan block still wins over overall and pooled`() {
        // Guard against future drift: when Cursor sends both legacy `plan` and the newer `overall`
        // blocks, the existing percent precedence must remain intact.
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: "user",
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 1500,
                            limit: 5000,
                            remaining: 3500,
                            breakdown: nil,
                            autoPercentUsed: nil,
                            apiPercentUsed: nil,
                            totalPercentUsed: 30.0),
                        onDemand: nil,
                        overall: CursorOverallUsage(enabled: true, used: 7384, limit: 10000, remaining: 2616)),
                    teamUsage: CursorTeamUsage(
                        onDemand: nil,
                        pooled: CursorPooledUsage(
                            enabled: true,
                            used: 12_725_135,
                            limit: 28_122_000,
                            remaining: 15_396_865))),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed == 30.0)
        #expect(snapshot.planUsedUSD == 15.0)
        #expect(snapshot.planLimitUSD == 50.0)
    }
}
