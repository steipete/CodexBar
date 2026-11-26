import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AntigravityExtendedMetadataTests {
    @Test
    func `GetUserStatus decodes proto3 int64 string and integer credits topUpStatus and metadata`() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "credits@example.com",
            "name": "Fixture User",
            "pro": true,
            "g1Tier": "GOOGLE_ONE_AI",
            "teamId": "team-123",
            "teamStatus": "USER_TEAM_STATUS_ACTIVE",
            "userUsedPromptCredits": "75",
            "userUsedFlowCredits": 12,
            "userTier": {
              "id": "g1-pro-tier",
              "name": "Google AI Pro"
            },
            "planStatus": {
              "planStart": "2026-11-01T00:00:00Z",
              "planEnd": "2026-12-01T00:00:00Z",
              "availablePromptCredits": "425",
              "usedPromptCredits": 75,
              "availableFlowCredits": "88",
              "usedFlowCredits": "12",
              "availableFlexCredits": "250",
              "usedFlexCredits": 10,
              "topUpStatus": {
                "topUpTransactionStatus": "TRANSACTION_STATUS_SUCCEEDED",
                "topUpEnabled": true,
                "monthlyTopUpAmount": "1000",
                "topUpSpent": 10,
                "topUpIncrement": "100",
                "topUpCriteriaMet": true
              },
              "planInfo": {
                "planName": "Pro",
                "teamsTier": "TEAMS_TIER_PRO",
                "monthlyPromptCredits": "500",
                "monthlyFlowCredits": 100,
                "monthlyFlexCreditPurchaseAmount": "500",
                "canBuyMoreCredits": true
              }
            }
          }
        }
        """

        let snapshot = try AntigravityStatusProbe.parseUserStatusResponse(Data(json.utf8))
        #expect(snapshot.accountEmail == "credits@example.com")
        #expect(snapshot.accountPlan == "Google AI Pro")

        let credits = try #require(snapshot.credits)
        #expect(credits.prompt == AntigravityCreditPool(available: 425, used: 75, userUsed: 75, monthly: 500))
        #expect(credits.flow == AntigravityCreditPool(available: 88, used: 12, userUsed: 12, monthly: 100))
        #expect(credits.flex == AntigravityCreditPool(available: 250, used: 10))
        #expect(credits.monthlyFlexPurchaseAmount == 500)
        #expect(credits.canBuyMoreCredits == true)
        #expect(credits.planStart == ISO8601DateParser.parse("2026-11-01T00:00:00Z"))
        #expect(credits.planEnd == ISO8601DateParser.parse("2026-12-01T00:00:00Z"))

        let topUp = try #require(credits.topUpStatus)
        #expect(topUp.enabled == true)
        #expect(topUp.criteriaMet == true)
        #expect(topUp.monthlyAmount == 1000)
        #expect(topUp.spent == 10)
        #expect(topUp.increment == 100)
        #expect(topUp.transactionStatus == "TRANSACTION_STATUS_SUCCEEDED")

        let metadata = try #require(snapshot.accountMetadata)
        #expect(metadata.g1Tier == "GOOGLE_ONE_AI")
        #expect(metadata.teamsTier == "TEAMS_TIER_PRO")
        #expect(metadata.isPro == true)
        #expect(metadata.teamId == "team-123")
        #expect(metadata.teamStatus == "USER_TEAM_STATUS_ACTIVE")
    }

    @Test
    func `quota summary decodes root buckets remainingAmount refreshWindowLabel and modelAvailabilities`() throws {
        let camelJSON = """
        {
          "buckets": [
            {
              "bucketId": "gemini-allowance",
              "displayName": "Allowance",
              "refreshWindowLabel": "weekly",
              "remaining": { "case": "remainingFraction", "value": 0.6 },
              "remainingAmount": "300"
            },
            {
              "bucketId": "3p-allowance",
              "displayName": "Third Party",
              "refreshWindowLabel": "5h",
              "remainingFraction": 0.8,
              "remaining": { "case": "remainingAmount", "value": 40 }
            }
          ],
          "modelAvailabilities": {
            "gemini-3.1-pro-preview": {
              "state": "MODEL_AVAILABILITY_STATE_CONGESTED",
              "explanation": "High demand in region"
            },
            "gemini-3.7-flash": {
              "state": "MODEL_AVAILABILITY_STATE_OPERATIONAL"
            }
          }
        }
        """

        let local = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(camelJSON.utf8))
        let summary = try #require(local.quotaSummary)
        #expect(summary.groups.count == 1)
        #expect(summary.groups[0].buckets.map(\.remainingAmount) == [300, 40])
        #expect(summary.groups[0].buckets.map(\.refreshWindowLabel) == ["weekly", "5h"])
        #expect(summary.modelAvailabilities["gemini-3.1-pro-preview"] == AntigravityModelAvailability(
            state: "MODEL_AVAILABILITY_STATE_CONGESTED",
            explanation: "High demand in region"))

        let usage = try local.toUsageSnapshot()
        let windows = try #require(usage.extraRateWindows)
        #expect(windows.map(\.window.windowMinutes) == [300, 10080])
        let availabilitySection = usage.details.first { $0.title == "Model availability" }
        #expect(availabilitySection?.rows.count == 1)
        #expect(availabilitySection?.rows.first?.value == "Congested")
        #expect(availabilitySection?.rows.first?.secondaryValue == "High demand in region")
        let amountSection = usage.details.first { $0.title == "Bucket amounts" }
        #expect(amountSection?.rows.map(\.value) == ["300 remaining", "40 remaining"])

        let snakeReportJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "buckets": [
                {
                  "bucket_id": "gemini-allowance",
                  "display_name": "Allowance",
                  "refresh_window_label": "weekly",
                  "remaining_fraction": 0.6,
                  "remaining_amount": "300"
                }
              ],
              "model_availabilities": {
                "gemini-3.1-pro-preview": {
                  "state": "MODEL_AVAILABILITY_STATE_HIGH_TRAFFIC",
                  "explanation": "Throttled"
                }
              }
            }
          }
        }
        """
        let cli = try AntigravityStatusProbe.parseCLIUsageReport(Data(snakeReportJSON.utf8))
        #expect(cli.quotaSummary?.groups.first?.buckets.first?.remainingAmount == 300)
        #expect(cli.quotaSummary?.groups.first?.buckets.first?.refreshWindowLabel == "weekly")
        #expect(cli.quotaSummary?.modelAvailabilities["gemini-3.1-pro-preview"]?.state
            == "MODEL_AVAILABILITY_STATE_HIGH_TRAFFIC")
    }

    @Test
    func `modelAvailability excludes unprefixed operational and unspecified states`() throws {
        let json = """
        {
          "buckets": [
            {
              "bucketId": "gemini-allowance",
              "displayName": "Allowance",
              "refreshWindowLabel": "weekly",
              "remainingFraction": 0.9
            }
          ],
          "modelAvailabilities": {
            "model-short-operational": { "state": "OPERATIONAL" },
            "model-short-unspecified": { "state": "UNSPECIFIED" },
            "model-lower-operational": { "state": " operational " },
            "model-prefixed-operational": { "state": "MODEL_AVAILABILITY_STATE_OPERATIONAL" },
            "model-prefixed-unspecified": { "state": "MODEL_AVAILABILITY_STATE_UNSPECIFIED" },
            "model-numeric-zero": { "state": 0 },
            "model-numeric-one": { "state": 1 },
            "model-congested": { "state": "CONGESTED", "explanation": "Busy" }
          }
        }
        """

        let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()
        let availability = try #require(usage.details.first { $0.title == "Model availability" })
        #expect(availability.rows.count == 1)
        #expect(availability.rows.first?.id == "antigravity-availability-model-congested")
        #expect(availability.rows.first?.value == "Congested")
        #expect(availability.rows.first?.secondaryValue == "Busy")

        let allHealthyJSON = """
        {
          "buckets": [
            {
              "bucketId": "gemini-allowance",
              "displayName": "Allowance",
              "refreshWindowLabel": "weekly",
              "remainingFraction": 0.9
            }
          ],
          "modelAvailabilities": {
            "model-short-operational": { "state": "OPERATIONAL" },
            "model-short-unspecified": { "state": "UNSPECIFIED" }
          }
        }
        """
        let healthyUsage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(allHealthyJSON.utf8))
            .toUsageSnapshot()
        #expect(!healthyUsage.details.contains { $0.title == "Model availability" })
    }

    @Test
    func `parseCLIUsageReport decodes snake_case remaining oneof cases`() throws {
        let fractionReportJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "buckets": [
                {
                  "bucket_id": "gemini-allowance",
                  "display_name": "Allowance",
                  "refresh_window_label": "weekly",
                  "remaining": { "case": "remaining_fraction", "value": 0.6 }
                }
              ]
            }
          }
        }
        """
        let fractionSnapshot = try AntigravityStatusProbe.parseCLIUsageReport(Data(fractionReportJSON.utf8))
        let fractionBucket = try #require(fractionSnapshot.quotaSummary?.groups.first?.buckets.first)
        #expect(fractionBucket.remainingFraction == 0.6)
        #expect(fractionBucket.remainingAmount == nil)

        let amountReportJSON = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "buckets": [
                {
                  "bucket_id": "gemini-allowance",
                  "display_name": "Allowance",
                  "refresh_window_label": "weekly",
                  "remaining_fraction": 0.6,
                  "remaining": { "case": "remaining_amount", "value": "300" }
                }
              ]
            }
          }
        }
        """
        let amountSnapshot = try AntigravityStatusProbe.parseCLIUsageReport(Data(amountReportJSON.utf8))
        let amountBucket = try #require(amountSnapshot.quotaSummary?.groups.first?.buckets.first)
        #expect(amountBucket.remainingFraction == 0.6)
        #expect(amountBucket.remainingAmount == 300)
    }

    @Test
    func `fetchSnapshot merges credits and accountMetadata from GetUserStatus`() async throws {
        let summaryJSON = antigravityQuotaSummaryJSON()
        let userStatusJSON = """
        {
          "code": 0,
          "userStatus": {
            "email": "merged@example.com",
            "pro": true,
            "g1Tier": "GOOGLE_ONE_HELIUM",
            "userTier": { "name": "Google AI Ultra" },
            "planStatus": {
              "planEnd": "2026-12-15T00:00:00Z",
              "availablePromptCredits": "900",
              "usedPromptCredits": "100",
              "planInfo": {
                "monthlyPromptCredits": "1000"
              }
            }
          }
        }
        """
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 41001,
            csrfToken: "token",
            source: .languageServer)
        let context = AntigravityStatusProbe.RequestContext(endpoints: [endpoint], timeout: 5)
        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(context: context) { payload, _, _ in
            if payload.path.hasSuffix("RetrieveUserQuotaSummary") {
                return Data(summaryJSON.utf8)
            }
            if payload.path.hasSuffix("GetUserStatus") {
                return Data(userStatusJSON.utf8)
            }
            throw AntigravityStatusProbeError.apiError("unexpected")
        }

        #expect(snapshot.accountEmail == "merged@example.com")
        #expect(snapshot.accountPlan == "Google AI Ultra")
        #expect(snapshot.credits?.prompt == AntigravityCreditPool(available: 900, used: 100, monthly: 1000))
        #expect(snapshot.accountMetadata?.g1Tier == "GOOGLE_ONE_HELIUM")
        #expect(snapshot.accountMetadata?.isPro == true)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.subscriptionRenewsAt == ISO8601DateParser.parse("2026-12-15T00:00:00Z"))
        #expect(usage.subscriptionExpiresAt == nil)
        #expect(usage.antigravityCredits == snapshot.credits)
        #expect(usage.antigravityAccountMetadata == snapshot.accountMetadata)
        let creditsSection = try #require(usage.details.first { $0.title == "Credits" })
        #expect(creditsSection.rows.first?.value == "900 / 1000")
        #expect(creditsSection.rows.first?.progress?.used == 100)
        #expect(creditsSection.rows.first?.progress?.total == 1000)
    }

    @Test
    func `remote fetcher decodes g1Tier gcpManaged subscription URIs and availableCredits`() async throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "synthetic-token",
            refreshToken: nil,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: nil,
            email: "remote@example.com",
            projectID: "proj-1")
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
        let fetcher = AntigravityRemoteUsageFetcher(
            homeDirectory: "/synthetic-antigravity-home",
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: GeminiAPITestHelpers.dataLoader { request in
                let url = try #require(request.url)
                let body: Data = switch url.path {
                case "/v1internal:loadCodeAssist":
                    GeminiAPITestHelpers.jsonData([
                        "g1Tier": "GOOGLE_ONE_AI",
                        "gcpManaged": true,
                        "manageSubscriptionUri": "https://one.google.com/subscriptions",
                        "upgradeSubscriptionUri": "https://one.google.com/upgrade",
                        "paidTier": [
                            "id": "g1-pro",
                            "name": "Pro",
                            "availableCredits": [
                                [
                                    "creditType": "GOOGLE_ONE_AI",
                                    "creditAmount": "250",
                                    "minimumCreditAmountForUsage": "10",
                                ],
                            ],
                        ],
                    ])
                case "/v1internal:retrieveUserQuotaSummary":
                    Data(antigravityQuotaSummaryJSON().utf8)
                default:
                    Data("{}".utf8)
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: body)
            })

        let snapshot = try await fetcher.fetch()
        #expect(snapshot.accountMetadata?.g1Tier == "GOOGLE_ONE_AI")
        #expect(snapshot.accountMetadata?.gcpManaged == true)
        #expect(snapshot.accountMetadata?.manageSubscriptionURI == "https://one.google.com/subscriptions")
        #expect(snapshot.accountMetadata?.upgradeSubscriptionURI == "https://one.google.com/upgrade")
        #expect(snapshot.credits?.availableCredits == [
            AntigravityTierCredit(creditType: "GOOGLE_ONE_AI", creditAmount: 250, minimumCreditAmountForUsage: 10),
        ])

        let usage = try snapshot.toUsageSnapshot()
        #expect(AntigravityProviderDescriptor.subscriptionDashboardURL(from: usage)?.absoluteString
            == "https://one.google.com/subscriptions")
        let creditsSection = try #require(usage.details.first { $0.title == "Credits" })
        #expect(creditsSection.rows.first?.label == "Google One credits")
        #expect(creditsSection.rows.first?.value == "250 remaining")
    }

    @Test
    func `toUsageSnapshot respects showCredits primaryPool and optional details visibility`() throws {
        let now = Date(timeIntervalSince1970: 1_787_832_000)
        let summaryData = Data(antigravityQuotaSummaryJSON(
            geminiSession: 0.9,
            geminiWeekly: 0.7,
            claudeSession: 0.5,
            claudeWeekly: 0.3).utf8)
        let base = try AntigravityStatusProbe.parseQuotaSummaryResponse(summaryData)
        let enriched = base.withIdentity(from: AntigravityStatusSnapshot(
            modelQuotas: [],
            accountEmail: "user@example.com",
            accountPlan: "Free",
            source: .local,
            credits: AntigravityCreditsSnapshot(
                prompt: AntigravityCreditPool(available: 50, used: 10, monthly: 60),
                planEnd: now.addingTimeInterval(86400)),
            accountMetadata: AntigravityAccountMetadata(isPro: false)))

        let defaultUsage = try enriched.toUsageSnapshot()
        #expect(defaultUsage.extraRateWindows?.first?.id == "antigravity-quota-summary-gemini-5h")
        #expect(defaultUsage.primary?.remainingPercent.rounded() == 70)
        #expect(defaultUsage.subscriptionExpiresAt == now.addingTimeInterval(86400))
        #expect(defaultUsage.subscriptionRenewsAt == nil)
        #expect(defaultUsage.details.contains { $0.title == "Credits" })

        let reorderedUsage = try enriched.toUsageSnapshot(primaryPool: .claudeGPTWeekly, showCredits: false)
        #expect(reorderedUsage.extraRateWindows?.first?.id == "antigravity-quota-summary-3p-weekly")
        #expect(reorderedUsage.primary?.remainingPercent.rounded() == 30)
        #expect(reorderedUsage.secondary?.remainingPercent.rounded() == 70)
        #expect(!reorderedUsage.details.contains { $0.title == "Credits" })

        let metadata = try #require(ProviderDefaults.metadata[.antigravity])
        func cardDetailsCount(showOptional: Bool) -> Int {
            UsageMenuCardView.Model.make(.init(
                provider: .antigravity,
                metadata: metadata,
                snapshot: defaultUsage,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: showOptional,
                hidePersonalInfo: false,
                now: now)).providerDetails.count
        }

        #expect(cardDetailsCount(showOptional: true) == 1)
        #expect(cardDetailsCount(showOptional: false) == 0)
    }

    @Test
    func `UsageSnapshot JSON round-trip preserves extended fields and decodes legacy payloads`() throws {
        let now = Date(timeIntervalSince1970: 1_787_832_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            antigravityCredits: AntigravityCreditsSnapshot(
                prompt: AntigravityCreditPool(available: 400, used: 100, monthly: 500),
                canBuyMoreCredits: true),
            antigravityAccountMetadata: AntigravityAccountMetadata(
                g1Tier: "GOOGLE_ONE_AI",
                isPro: true,
                manageSubscriptionURI: "https://one.google.com/manage"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: "roundtrip@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(decoded.antigravityCredits == snapshot.antigravityCredits)
        #expect(decoded.antigravityAccountMetadata == snapshot.antigravityAccountMetadata)

        let legacyJSON = """
        {
          "primary": null,
          "secondary": null,
          "tertiary": null,
          "updatedAt": \(now.timeIntervalSinceReferenceDate)
        }
        """
        let legacyDecoded = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(legacyDecoded.antigravityCredits == nil)
        #expect(legacyDecoded.antigravityAccountMetadata == nil)
    }
}
