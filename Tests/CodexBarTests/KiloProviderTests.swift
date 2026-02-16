import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCore

// MARK: - Settings & Token Resolver

@Suite
struct KiloSettingsReaderTests {
    @Test
    func readsTokenFromEnvironmentVariable() {
        let env = ["KILO_API_KEY": "test-api-key"]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == "test-api-key")
    }

    @Test
    func returnsNilWhenMissing() {
        let env: [String: String] = [:]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == nil)
    }

    @Test
    func apiTokenStripsQuotes() {
        let env = ["KILO_API_KEY": "\"quoted-token\""]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == "quoted-token")
    }

    @Test
    func normalizesQuotedToken() {
        let env = ["KILO_API_KEY": "'single-quoted'"]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == "single-quoted")
    }
}

@Suite
struct KiloTokenResolverTests {
    @Test
    func resolvesTokenFromEnvironment() {
        let env = ["KILO_API_KEY": "test-api-key"]
        let token = ProviderTokenResolver.kiloToken(environment: env)
        #expect(token == "test-api-key")
    }

    @Test
    func returnsNilWhenMissing() {
        let env: [String: String] = [:]
        let token = ProviderTokenResolver.kiloToken(environment: env)
        #expect(token == nil)
    }
}

// MARK: - CLI Stats Parser

@Suite
struct KiloCLIStatsParserTests {
    @Test
    func parsesRealCLIOutput() {
        let output = """
        ┌────────────────────────────────────────────────────────┐
        │                       OVERVIEW                         │
        ├────────────────────────────────────────────────────────┤
        │Sessions                                              2 │
        │Messages                                            285 │
        │Days                                                  1 │
        └────────────────────────────────────────────────────────┘

        ┌────────────────────────────────────────────────────────┐
        │                    COST & TOKENS                       │
        ├────────────────────────────────────────────────────────┤
        │Total Cost                                        $1.19 │
        │Input                                              1.4M │
        │Output                                            46.1K │
        │Cache Read                                        20.2M │
        │Cache Write                                           0 │
        └────────────────────────────────────────────────────────┘
        """

        let stats = KiloCLIFetchStrategy.parseCLIStatsOutputInternal(output)
        #expect(stats.sessions == 2)
        #expect(stats.messages == 285)
        #expect(stats.totalCost == 1.19)
        #expect(stats.inputTokens == 1_400_000)
        #expect(stats.outputTokens == 46_100)
        #expect(stats.cacheReadTokens == 20_200_000)
    }

    @Test
    func parsesEmptyOutput() {
        let stats = KiloCLIFetchStrategy.parseCLIStatsOutputInternal("")
        #expect(stats.sessions == 0)
        #expect(stats.messages == 0)
        #expect(stats.totalCost == 0)
        #expect(stats.inputTokens == 0)
        #expect(stats.outputTokens == 0)
        #expect(stats.cacheReadTokens == 0)
    }

    @Test
    func parseTokenCountSuffixes() {
        #expect(KiloCLIFetchStrategy.parseTokenCount("1.4M") == 1_400_000)
        #expect(KiloCLIFetchStrategy.parseTokenCount("46.1K") == 46_100)
        #expect(KiloCLIFetchStrategy.parseTokenCount("20.2M") == 20_200_000)
        #expect(KiloCLIFetchStrategy.parseTokenCount("1.5B") == 1_500_000_000)
        #expect(KiloCLIFetchStrategy.parseTokenCount("0") == 0)
        #expect(KiloCLIFetchStrategy.parseTokenCount("500") == 500)
    }
}

// MARK: - Batched API Response Parser

@Suite
struct KiloBatchedResponseParserTests {
    @Test
    func parsesSubscriptionWithCreditBlocks() throws {
        let json = """
        [
          {
            "result": {
              "data": {
                "creditBlocks": [
                  {
                    "id": "block-1",
                    "effective_date": "2026-02-01T00:00:00Z",
                    "expiry_date": null,
                    "balance_mUsd": 15000000,
                    "amount_mUsd": 19000000,
                    "is_free": false
                  }
                ],
                "totalBalance_mUsd": 15000000,
                "autoTopUpEnabled": false
              }
            }
          },
          {
            "result": {
              "data": {
                "subscription": {
                  "tier": "tier_19",
                  "currentPeriodUsageUsd": 3.50,
                  "currentPeriodBaseCreditsUsd": 19.0,
                  "currentPeriodBonusCreditsUsd": 9.50,
                  "nextBillingAt": "2026-03-15T00:00:00Z"
                }
              }
            }
          }
        ]
        """

        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.balanceDollars == 15.0)
        #expect(snapshot.hasSubscription == true)
        #expect(snapshot.planName == "Starter")
        #expect(snapshot.periodBaseCredits == 19.0)
        #expect(snapshot.periodBonusCredits == 9.50)
        #expect(snapshot.periodUsageDollars == 3.50)
        #expect(snapshot.periodResetsAt != nil)
        #expect(snapshot.creditBlocks.count == 1)
        #expect(snapshot.creditBlocks[0].balanceMUsd == 15_000_000)
        #expect(snapshot.autoTopUp == nil)
    }

    @Test
    func parsesProTier() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false}}},
          {"result": {"data": {"subscription": {"tier": "tier_49"}}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.planName == "Pro")
    }

    @Test
    func parsesExpertTier() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false}}},
          {"result": {"data": {"subscription": {"tier": "tier_199"}}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.planName == "Expert")
    }

    @Test
    func fallsBackToRawTierName() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false}}},
          {"result": {"data": {"subscription": {"tier": "tier_999"}}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.planName == "tier_999")
    }

    @Test
    func subscriptionWithoutTierDefaultsToKiloPass() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false}}},
          {"result": {"data": {"subscription": {"currentPeriodUsageUsd": 1.0, "currentPeriodBaseCreditsUsd": 19.0}}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.hasSubscription == true)
        #expect(snapshot.planName == "Kilo Pass")
        #expect(snapshot.periodBaseCredits == 19.0)
    }

    @Test
    func noSubscriptionSetsDefaults() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false}}},
          {"result": {"data": {}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.hasSubscription == false)
        #expect(snapshot.planName == nil)
        #expect(snapshot.periodBaseCredits == 0)
    }

    @Test
    func parsesAutoTopUpEnabled() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": true}}},
          {"result": {"data": {}}},
          {"result": {"data": {"amountCents": 5000}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.autoTopUp != nil)
        #expect(snapshot.autoTopUp?.enabled == true)
        #expect(snapshot.autoTopUp?.amountDollars == 50.0)
    }

    @Test
    func autoTopUpDisabledReturnsNil() throws {
        let json = """
        [
          {"result": {"data": {"creditBlocks": [], "totalBalance_mUsd": 0, "autoTopUpEnabled": false}}},
          {"result": {"data": {}}}
        ]
        """
        let snapshot = try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        #expect(snapshot.autoTopUp == nil)
    }

    @Test
    func invalidResponseThrows() {
        let json = """
        {"not": "an array"}
        """
        #expect(throws: KiloAPIError.self) {
            try KiloWebAPIFetchStrategy._parseBatchedResponse(Data(json.utf8))
        }
    }
}

// MARK: - Credit Block Consolidation (via toUsageSnapshot)

@Suite
struct KiloCreditBlockConsolidationTests {
    @Test
    func consolidatesNonExpiringBlocks() {
        let snapshot = KiloUsageSnapshot(
            creditBlocks: [
                KiloCreditBlock(id: "a", effectiveDateString: "2026-01-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 5_000_000, amountMUsd: 10_000_000, isFree: false),
                KiloCreditBlock(id: "b", effectiveDateString: "2026-02-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 3_000_000, amountMUsd: 8_000_000, isFree: false),
            ],
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let blocks = usage.kiloCreditBlocks!
        #expect(blocks.count == 1)
        #expect(blocks[0].id == "consolidated-permanent")
        #expect(blocks[0].balanceMUsd == 8_000_000)
        #expect(blocks[0].amountMUsd == 18_000_000)
        #expect(blocks[0].effectiveDateString == "2026-01-01T00:00:00Z")
    }

    @Test
    func keepsExpiringBlocksSeparate() {
        let snapshot = KiloUsageSnapshot(
            creditBlocks: [
                KiloCreditBlock(id: "a", effectiveDateString: "2026-01-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 5_000_000, amountMUsd: 10_000_000, isFree: false),
                KiloCreditBlock(id: "b", effectiveDateString: "2026-02-01T00:00:00Z", expiryDateString: "2026-06-01T00:00:00Z",
                                balanceMUsd: 3_000_000, amountMUsd: 5_000_000, isFree: false),
            ],
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let blocks = usage.kiloCreditBlocks!
        #expect(blocks.count == 2)
        #expect(blocks[0].id == "consolidated-permanent")
        #expect(blocks[1].id == "b")
        #expect(blocks[1].expiryDateString == "2026-06-01T00:00:00Z")
    }

    @Test
    func allFreeBlocksPreserveIsFree() {
        let snapshot = KiloUsageSnapshot(
            creditBlocks: [
                KiloCreditBlock(id: "a", effectiveDateString: "2026-01-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 1_000_000, amountMUsd: 5_000_000, isFree: true),
                KiloCreditBlock(id: "b", effectiveDateString: "2026-02-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 2_000_000, amountMUsd: 5_000_000, isFree: true),
            ],
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let blocks = usage.kiloCreditBlocks!
        #expect(blocks.count == 1)
        #expect(blocks[0].isFree == true)
    }

    @Test
    func mixedFreeAndPaidMarksNotFree() {
        let snapshot = KiloUsageSnapshot(
            creditBlocks: [
                KiloCreditBlock(id: "a", effectiveDateString: "2026-01-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 1_000_000, amountMUsd: 5_000_000, isFree: true),
                KiloCreditBlock(id: "b", effectiveDateString: "2026-02-01T00:00:00Z", expiryDateString: nil,
                                balanceMUsd: 2_000_000, amountMUsd: 10_000_000, isFree: false),
            ],
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let blocks = usage.kiloCreditBlocks!
        #expect(blocks[0].isFree == false)
    }

    @Test
    func onlyExpiringBlocksKeptIndividually() {
        let snapshot = KiloUsageSnapshot(
            creditBlocks: [
                KiloCreditBlock(id: "exp-1", effectiveDateString: "2026-01-01T00:00:00Z", expiryDateString: "2026-06-01T00:00:00Z",
                                balanceMUsd: 5_000_000, amountMUsd: 10_000_000, isFree: false),
                KiloCreditBlock(id: "exp-2", effectiveDateString: "2026-02-01T00:00:00Z", expiryDateString: "2026-07-01T00:00:00Z",
                                balanceMUsd: 3_000_000, amountMUsd: 8_000_000, isFree: false),
            ],
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let blocks = usage.kiloCreditBlocks!
        #expect(blocks.count == 2)
        #expect(blocks[0].id == "exp-1")
        #expect(blocks[1].id == "exp-2")
        // No consolidated-permanent entry
        #expect(blocks.allSatisfy { $0.id != "consolidated-permanent" })
    }

    @Test
    func emptyBlocksReturnsNil() {
        let snapshot = KiloUsageSnapshot(creditBlocks: [], updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.kiloCreditBlocks == nil)
    }
}

// MARK: - toUsageSnapshot Conversion

@Suite
struct KiloUsageSnapshotConversionTests {
    @Test
    func withSubscriptionHasPrimaryWindow() {
        let snapshot = KiloUsageSnapshot(
            periodBaseCredits: 19.0,
            periodBonusCredits: 9.50,
            periodUsageDollars: 5.0,
            hasSubscription: true,
            planName: "Starter",
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary != nil)
        let primary = usage.primary!
        let totalCredits = 19.0 + 9.50
        let expectedUsed = (5.0 / totalCredits) * 100
        #expect(abs(primary.usedPercent - expectedUsed) < 0.01)
    }

    @Test
    func withoutSubscriptionNoPrimaryWindow() {
        let snapshot = KiloUsageSnapshot(
            hasSubscription: false,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
    }

    @Test
    func markerPercentSetAtBonusBoundary() {
        let snapshot = KiloUsageSnapshot(
            periodBaseCredits: 19.0,
            periodBonusCredits: 9.50,
            hasSubscription: true,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let expectedMarker = (9.50 / 28.50) * 100
        #expect(usage.primary?.markerPercent != nil)
        #expect(abs(usage.primary!.markerPercent! - expectedMarker) < 0.01)
    }

    @Test
    func noBonusCreditsNoMarker() {
        let snapshot = KiloUsageSnapshot(
            periodBaseCredits: 19.0,
            periodBonusCredits: 0,
            hasSubscription: true,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.markerPercent == nil)
    }

    @Test
    func providerCostCarriesCLIStats() {
        let snapshot = KiloUsageSnapshot(
            cliCostDollars: 2.50,
            cliSessions: 3,
            cliMessages: 100,
            cliInputTokens: 500_000,
            cliOutputTokens: 50_000,
            cliCacheReadTokens: 1_000_000,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.providerCost != nil)
        #expect(usage.providerCost?.used == 2.50)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.period?.contains("3 sessions") == true)
        #expect(usage.providerCost?.period?.contains("100 messages") == true)
        #expect(usage.providerCost?.period?.contains("tokens") == true)
    }

    @Test
    func noCLIStatsNoCostSection() {
        let snapshot = KiloUsageSnapshot(updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.providerCost == nil)
    }

    @Test
    func autoTopUpTextGenerated() {
        let snapshot = KiloUsageSnapshot(
            autoTopUp: KiloAutoTopUp(enabled: true, amountDollars: 50),
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.kiloAutoTopUpText == "Auto top-up: $50")
    }

    @Test
    func autoTopUpWithoutAmountShowsOn() {
        let snapshot = KiloUsageSnapshot(
            autoTopUp: KiloAutoTopUp(enabled: true, amountDollars: 0),
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.kiloAutoTopUpText == "Auto top-up: On")
    }

    @Test
    func noAutoTopUpNoText() {
        let snapshot = KiloUsageSnapshot(updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.kiloAutoTopUpText == nil)
    }

    @Test
    func identityCarriesPlanName() {
        let snapshot = KiloUsageSnapshot(
            hasSubscription: true,
            planName: "Pro",
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.loginMethod(for: .kilo) == "Pro")
    }
}
