import CodexBarCore
import Foundation
import Testing

@Suite
struct CopilotUsageModelsTests {
    @Test
    func decodesQuotaSnapshotsPayload() throws {
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
    func decodesChatOnlyQuotaSnapshotsPayload() throws {
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
    func preservesMissingDateFieldsAsNil() throws {
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
    func preservesExplicitEmptyDateFields() throws {
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
    func decodesMonthlyAndLimitedQuotaPayload() throws {
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
    func doesNotAssumeFullQuotaWhenLimitedQuotasAreMissing() throws {
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
    func computesMonthlyFallbackPerQuotaOnlyWhenLimitedValueExists() throws {
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
    func mergesDirectAndMonthlyFallbackLanesWhenDirectIsPartial() throws {
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
    func decodesUnknownQuotaSnapshotKeysUsingFallback() throws {
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
    func ignoresPlaceholderKnownSnapshotWhenSelectingUnknownKeyFallback() throws {
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
    func derivesPercentRemainingWhenMissingButEntitlementExists() throws {
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
    func marksPercentRemainingAsUnavailableWhenUnderdetermined() throws {
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
    func marksPercentRemainingAsUnavailableWhenRemainingIsMissing() throws {
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
    func fallsBackToMonthlyWhenDirectSnapshotIsMissingRemaining() throws {
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
    func fallsBackToMonthlyWhenDirectSnapshotsLackComputablePercent() throws {
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
    func skipsMonthlyFallbackWhenMonthlyDenominatorIsZero() throws {
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
