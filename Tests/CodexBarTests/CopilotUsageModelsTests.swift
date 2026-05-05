import CodexBarCore
import Foundation
import Testing

struct CopilotUsageModelsTests {
    @Test
    func `decodes quota snapshots payload`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "assigned_date": "2025-01-01",
              "quota_reset_date": "2025-02-01",
              "quota_snapshots": {
                "premium_interactions": {
                  "entitlement": 500,
                  "remaining": 450,
                  "percent_remaining": 90,
                  "quota_id": "premium_interactions"
                },
                "chat": {
                  "entitlement": 300,
                  "remaining": 150,
                  "percent_remaining": 50,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.copilotPlan == "free")
        #expect(response.assignedDate == "2025-01-01")
        #expect(response.quotaResetDate == "2025-02-01")
        #expect(response.quotaSnapshots.premiumInteractions?.remaining == 450)
        #expect(response.quotaSnapshots.chat?.remaining == 150)
    }

    @Test
    func `decodes chat only quota snapshots payload`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 200,
                  "remaining": 75,
                  "percent_remaining": 37.5,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat?.quotaId == "chat")
        #expect(response.quotaSnapshots.chat?.entitlement == 200)
        #expect(response.quotaSnapshots.chat?.remaining == 75)
    }

    @Test
    func `preserves missing date fields as nil`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 200,
                  "remaining": 75,
                  "percent_remaining": 37.5,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.assignedDate == nil)
        #expect(response.quotaResetDate == nil)
    }

    @Test
    func `preserves explicit empty date fields`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "assigned_date": "",
              "quota_reset_date": "",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 200,
                  "remaining": 75,
                  "percent_remaining": 37.5,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.assignedDate?.isEmpty == true)
        #expect(response.quotaResetDate?.isEmpty == true)
    }

    @Test
    func `decodes monthly and limited quota payload`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "monthly_quotas": {
                "chat": "500",
                "completions": 300
              },
              "limited_user_quotas": {
                "chat": 125,
                "completions": "75"
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions?.quotaId == "completions")
        #expect(response.quotaSnapshots.premiumInteractions?.entitlement == 300)
        #expect(response.quotaSnapshots.premiumInteractions?.remaining == 75)
        #expect(response.quotaSnapshots.premiumInteractions?.percentRemaining == 25)

        #expect(response.quotaSnapshots.chat?.quotaId == "chat")
        #expect(response.quotaSnapshots.chat?.entitlement == 500)
        #expect(response.quotaSnapshots.chat?.remaining == 125)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 25)
    }

    @Test
    func `does not assume full quota when limited quotas are missing`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "monthly_quotas": {
                "chat": 500,
                "completions": 300
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat == nil)
    }

    @Test
    func `computes monthly fallback per quota only when limited value exists`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "monthly_quotas": {
                "chat": 500,
                "completions": 300
              },
              "limited_user_quotas": {
                "completions": 60
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions?.quotaId == "completions")
        #expect(response.quotaSnapshots.premiumInteractions?.entitlement == 300)
        #expect(response.quotaSnapshots.premiumInteractions?.remaining == 60)
        #expect(response.quotaSnapshots.premiumInteractions?.percentRemaining == 20)
        #expect(response.quotaSnapshots.chat == nil)
    }

    @Test
    func `merges direct and monthly fallback lanes when direct is partial`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 200,
                  "remaining": 75,
                  "percent_remaining": 37.5,
                  "quota_id": "chat"
                }
              },
              "monthly_quotas": {
                "chat": 500,
                "completions": 300
              },
              "limited_user_quotas": {
                "chat": 125,
                "completions": 60
              }
            }
            """)

        #expect(response.quotaSnapshots.chat?.quotaId == "chat")
        #expect(response.quotaSnapshots.chat?.entitlement == 200)
        #expect(response.quotaSnapshots.chat?.remaining == 75)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 37.5)

        #expect(response.quotaSnapshots.premiumInteractions?.quotaId == "completions")
        #expect(response.quotaSnapshots.premiumInteractions?.entitlement == 300)
        #expect(response.quotaSnapshots.premiumInteractions?.remaining == 60)
        #expect(response.quotaSnapshots.premiumInteractions?.percentRemaining == 20)
    }

    @Test
    func `decodes unknown quota snapshot keys using fallback`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "mystery_bucket": {
                  "entitlement": 100,
                  "remaining": 40,
                  "percent_remaining": 40,
                  "quota_id": "mystery_bucket"
                }
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat?.quotaId == "mystery_bucket")
        #expect(response.quotaSnapshots.chat?.entitlement == 100)
        #expect(response.quotaSnapshots.chat?.remaining == 40)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 40)
    }

    @Test
    func `ignores placeholder known snapshot when selecting unknown key fallback`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "premium_interactions": {},
                "mystery_bucket": {
                  "entitlement": 100,
                  "remaining": 40,
                  "percent_remaining": 40,
                  "quota_id": "mystery_bucket"
                }
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat?.quotaId == "mystery_bucket")
        #expect(response.quotaSnapshots.chat?.hasPercentRemaining == true)
    }

    @Test
    func `derives percent remaining when missing but entitlement exists`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 120,
                  "remaining": 30,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.quotaSnapshots.chat?.hasPercentRemaining == true)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 25)
    }

    @Test
    func `marks percent remaining as unavailable when underdetermined`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "remaining": 30,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.quotaSnapshots.chat?.hasPercentRemaining == false)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 0)
    }

    @Test
    func `marks percent remaining as unavailable when remaining is missing`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 120,
                  "quota_id": "chat"
                }
              }
            }
            """)

        #expect(response.quotaSnapshots.chat?.hasPercentRemaining == false)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 0)
    }

    @Test
    func `falls back to monthly when direct snapshot is missing remaining`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "entitlement": 120,
                  "quota_id": "chat"
                }
              },
              "monthly_quotas": {
                "chat": 400
              },
              "limited_user_quotas": {
                "chat": 100
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat?.quotaId == "chat")
        #expect(response.quotaSnapshots.chat?.entitlement == 400)
        #expect(response.quotaSnapshots.chat?.remaining == 100)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 25)
        #expect(response.quotaSnapshots.chat?.hasPercentRemaining == true)
    }

    @Test
    func `falls back to monthly when direct snapshots lack computable percent`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "quota_snapshots": {
                "chat": {
                  "remaining": 30,
                  "quota_id": "chat"
                }
              },
              "monthly_quotas": {
                "chat": 400
              },
              "limited_user_quotas": {
                "chat": 100
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat?.quotaId == "chat")
        #expect(response.quotaSnapshots.chat?.entitlement == 400)
        #expect(response.quotaSnapshots.chat?.remaining == 100)
        #expect(response.quotaSnapshots.chat?.percentRemaining == 25)
        #expect(response.quotaSnapshots.chat?.hasPercentRemaining == true)
    }

    @Test
    func `skips monthly fallback when monthly denominator is zero`() throws {
        let response = try Self.decodeFixture(
            """
            {
              "copilot_plan": "free",
              "monthly_quotas": {
                "chat": 0
              },
              "limited_user_quotas": {
                "chat": 0
              }
            }
            """)

        #expect(response.quotaSnapshots.premiumInteractions == nil)
        #expect(response.quotaSnapshots.chat == nil)
    }

    private static func decodeFixture(_ fixture: String) throws -> CopilotUsageResponse {
        try JSONDecoder().decode(CopilotUsageResponse.self, from: Data(fixture.utf8))
    }
}
