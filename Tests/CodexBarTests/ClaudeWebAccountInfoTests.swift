import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeWebAccountInfoTests {
    @Test
    func `selected organization determines the team seat label`() {
        let json = """
        {
          "email_address": "steipete@gmail.com",
          "memberships": [
            {
              "seat_tier": "team_standard",
              "organization": {
                "uuid": "org-standard",
                "name": "Standard Org",
                "rate_limit_tier": "claude_team",
                "billing_type": "stripe_subscription"
              }
            },
            {
              "seat_tier": "team_tier_1",
              "organization": {
                "uuid": "org-premium",
                "name": "Premium Org",
                "rate_limit_tier": "claude_team",
                "billing_type": "stripe_subscription"
              }
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let premium = ClaudeWebAPIFetcher._parseAccountInfoForTesting(data, orgId: "org-premium")
        let standard = ClaudeWebAPIFetcher._parseAccountInfoForTesting(data, orgId: "org-standard")
        #expect(premium?.loginMethod == "Claude Team Premium")
        #expect(standard?.loginMethod == "Claude Team Standard")
    }

    @Test
    func `enterprise membership preserves its plan when it has a legacy seat tier`() {
        let json = """
        {
          "email_address": "enterprise@example.com",
          "memberships": [
            {
              "seat_tier": "team_tier_1",
              "organization": {
                "uuid": "org-enterprise",
                "name": "Enterprise Org",
                "rate_limit_tier": "claude_enterprise",
                "billing_type": "stripe_subscription"
              }
            }
          ]
        }
        """
        let account = ClaudeWebAPIFetcher._parseAccountInfoForTesting(Data(json.utf8), orgId: "org-enterprise")
        #expect(account?.loginMethod == "Claude Enterprise")
    }
}
