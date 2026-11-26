import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
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
        #expect(reorderedUsage.primary?.remainingPercent.rounded() == 70)
        #expect(reorderedUsage.secondary?.remainingPercent.rounded() == 30)
        let reorderedLabels = AntigravityProviderDescriptor.descriptor.presentation.rateWindowLabels(
            metadata: AntigravityProviderDescriptor.descriptor.metadata,
            snapshot: reorderedUsage)
        #expect(reorderedLabels.primary == "Gemini Models")
        #expect(reorderedLabels.secondary == "Claude and GPT")
        let resolvedPreferred = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: reorderedUsage,
            supportsAverage: false,
            antigravityPrimaryPool: .claudeGPTWeekly)
        #expect(resolvedPreferred?.remainingPercent.rounded() == 30)
        #expect(!reorderedUsage.details.contains { $0.title == "Credits" })

        let metadata = try #require(ProviderDefaults.metadata[.antigravity])
        func cardDetails(showOptional: Bool) -> [ProviderDetailSection] {
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
                now: now)).providerDetails
        }

        let visibleWithOptional = cardDetails(showOptional: true)
        #expect(visibleWithOptional.count == 2)
        #expect(visibleWithOptional.map(\.title) == ["Credits", "Quota groups"])
        #expect(cardDetails(showOptional: false).isEmpty)
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
        #expect(legacyDecoded.antigravityCatalog == nil)

        let fullCatalog = AntigravityCatalogSnapshot(
            bucketAmounts: [
                AntigravityQuotaBucketAmount(
                    bucketId: "gemini-5h",
                    displayName: "5-hour",
                    groupName: "Gemini",
                    remainingAmount: 42,
                    remainingFraction: 0.7,
                    resetsAt: now.addingTimeInterval(3600)),
            ],
            modelAvailabilities: [
                "gemini-3.7-flash": AntigravityModelAvailability(state: "MODEL_AVAILABILITY_STATE_OPERATIONAL"),
                "gemini-3.1-pro-preview": AntigravityModelAvailability(
                    state: "MODEL_AVAILABILITY_STATE_CONGESTED",
                    explanation: "Busy"),
            ],
            quotaGroups: [
                AntigravityQuotaGroupRoster(
                    displayName: "Gemini Models",
                    description: "Models within this group: Gemini Flash, Gemini Pro",
                    models: ["Gemini Flash", "Gemini Pro"],
                    bucketIds: ["gemini-5h"]),
            ],
            modelCatalog: [
                AntigravityModelCatalogEntry(
                    modelId: "gemini-3.1-pro-preview",
                    label: "Gemini 3.1 Pro",
                    creditMultiplier: 1.5,
                    pricingType: "MODEL_PRICING_TYPE_STATIC_CREDIT",
                    isPremium: true,
                    tagTitle: "New"),
            ])
        let catalogSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            antigravityCatalog: fullCatalog,
            updatedAt: now)
        let catalogEncoded = try JSONEncoder().encode(catalogSnapshot)
        let catalogDecoded = try JSONDecoder().decode(UsageSnapshot.self, from: catalogEncoded)
        #expect(catalogDecoded.antigravityCatalog == fullCatalog)
    }

    @Test
    func `GetUserStatus resolves Ultra tier over generic Pro name and extracts catalog attributes`() throws {
        let userStatusJSON = """
        {
          "code": 0,
          "userStatus": {
            "email": "ultra@example.com",
            "g1Tier": "G1_ULTRA_TIER",
            "userTier": {
              "id": "g1-ultra-tier",
              "name": "Pro"
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3.1 Pro",
                  "modelOrAlias": { "model": "gemini-3.1-pro" },
                  "quotaInfo": { "remainingFraction": 0.8 },
                  "creditMultiplier": "1.5",
                  "pricingType": "MODEL_PRICING_TYPE_STATIC_CREDIT",
                  "isPremium": true,
                  "tagTitle": "Flagship"
                },
                {
                  "label": "Claude Opus 4.6",
                  "model_or_alias": { "model": "claude-opus-4-6" },
                  "credit_multiplier": 2,
                  "pricing_type": 2,
                  "premium": true,
                  "tag_title": "Thinking"
                }
              ]
            }
          }
        }
        """

        let identity = try AntigravityStatusProbe.parseUserStatusResponse(Data(userStatusJSON.utf8))
        #expect(identity.accountPlan == "Google AI Ultra")
        #expect(identity.modelCatalog.count == 2)
        #expect(identity.modelCatalog.first { $0.modelId == "gemini-3.1-pro" } == AntigravityModelCatalogEntry(
            modelId: "gemini-3.1-pro",
            label: "Gemini 3.1 Pro",
            creditMultiplier: 1.5,
            pricingType: "MODEL_PRICING_TYPE_STATIC_CREDIT",
            isPremium: true,
            tagTitle: "Flagship"))
        #expect(identity.modelCatalog.first { $0.modelId == "claude-opus-4-6" } == AntigravityModelCatalogEntry(
            modelId: "claude-opus-4-6",
            label: "Claude Opus 4.6",
            creditMultiplier: 2,
            pricingType: "MODEL_PRICING_TYPE_API",
            isPremium: true,
            tagTitle: "Thinking"))

        let summaryData = Data(antigravityQuotaSummaryJSON().utf8)
        let summary = try AntigravityStatusProbe.parseQuotaSummaryResponse(summaryData)
        let merged = summary.withIdentity(from: identity)
        #expect(merged.accountPlan == "Google AI Ultra")
        #expect(merged.modelCatalog.count == 2)

        let usage = try merged.toUsageSnapshot()
        #expect(usage.antigravityCatalog?.modelCatalog?.count == 2)
        #expect(usage.antigravityCatalog?.quotaGroups?.count == 2)
        let catalogSection = try #require(usage.details.first { $0.title == "Model catalog" })
        #expect(catalogSection.rows.count == 2)
        #expect(catalogSection.rows.first?.value == "1.5× · Static credit")
        #expect(catalogSection.rows.first?.secondaryValue == "Premium · Flagship")
        #expect(usage.details.contains { $0.title == "Quota groups" })
    }

    @Test
    func `quota summary UsageSnapshot preserves operational modelAvailabilities and bucketAmounts`() throws {
        let json = """
        {
          "buckets": [
            {
              "bucketId": "gemini-allowance",
              "displayName": "Allowance",
              "refreshWindowLabel": "weekly",
              "remainingFraction": 0.6,
              "remainingAmount": "300"
            },
            {
              "bucketId": "3p-allowance",
              "displayName": "Third Party",
              "refreshWindowLabel": "5h",
              "remainingFraction": 0.8,
              "remainingAmount": 40
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

        let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()
        let catalog = try #require(usage.antigravityCatalog)
        #expect(catalog.bucketAmounts?.map(\.remainingAmount) == [300, 40])
        #expect(catalog.modelAvailabilities?["gemini-3.7-flash"]?.state == "MODEL_AVAILABILITY_STATE_OPERATIONAL")
        #expect(catalog.modelAvailabilities?["gemini-3.1-pro-preview"]?.state == "MODEL_AVAILABILITY_STATE_CONGESTED")

        let availabilitySection = try #require(usage.details.first { $0.title == "Model availability" })
        #expect(availabilitySection.rows.count == 1)
    }

    @Test
    func `GetUserStatus and GetCommandModelConfigs drop malformed creditMultiplier while preserving siblings`() throws {
        let userStatusJSON = """
        {
          "code": 0,
          "userStatus": {
            "email": "resilient@example.com",
            "g1Tier": "G1_ULTRA_TIER",
            "userTier": {
              "id": "g1-ultra-tier",
              "name": "Google AI Pro"
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3.1 Pro",
                  "modelOrAlias": { "model": "gemini-3.1-pro" },
                  "quotaInfo": { "remainingFraction": 0.75 },
                  "creditMultiplier": "1.5",
                  "pricingType": "MODEL_PRICING_TYPE_STATIC_CREDIT",
                  "isPremium": true,
                  "tagTitle": "Flagship"
                },
                {
                  "label": "Gemini 3 NaN",
                  "modelOrAlias": { "model": "gemini-3-nan" },
                  "quotaInfo": { "remainingFraction": 0.5 },
                  "creditMultiplier": "NaN",
                  "pricingType": "MODEL_PRICING_TYPE_API"
                },
                {
                  "label": "Gemini 3 Infinity",
                  "modelOrAlias": { "model": "gemini-3-inf" },
                  "creditMultiplier": "Infinity"
                }
              ]
            }
          }
        }
        """

        let userStatus = try AntigravityStatusProbe.parseUserStatusResponse(Data(userStatusJSON.utf8))
        #expect(userStatus.accountPlan == "Google AI Ultra")
        #expect(userStatus.modelQuotas.count == 2)
        #expect(userStatus.modelCatalog.count == 2)
        #expect(userStatus.modelCatalog.first { $0.modelId == "gemini-3.1-pro" }?.creditMultiplier == 1.5)
        let nanEntry = try #require(userStatus.modelCatalog.first { $0.modelId == "gemini-3-nan" })
        #expect(nanEntry.creditMultiplier == nil)
        #expect(nanEntry.pricingType == "MODEL_PRICING_TYPE_API")
        #expect(!userStatus.modelCatalog.contains { $0.modelId == "gemini-3-inf" })

        let commandJSON = """
        {
          "code": 0,
          "clientModelConfigs": [
            {
              "label": "Claude Opus 4.6",
              "model_or_alias": { "model": "claude-opus-4-6" },
              "quota_info": { "remaining_fraction": 0.6 },
              "credit_multiplier": 2
            },
            {
              "label": "Broken Multiplier",
              "model_or_alias": { "model": "broken-model" },
              "quota_info": { "remaining_fraction": 0.4 },
              "credit_multiplier": "not-a-number"
            }
          ]
        }
        """

        let commandSnapshot = try AntigravityStatusProbe.parseCommandModelResponse(Data(commandJSON.utf8))
        #expect(commandSnapshot.modelQuotas.count == 2)
        #expect(commandSnapshot.modelCatalog.count == 1)
        #expect(commandSnapshot.modelCatalog.first?.modelId == "claude-opus-4-6")
        #expect(commandSnapshot.modelCatalog.first?.creditMultiplier == 2)
    }

    @Test
    func `toUsageSnapshot formats huge finite creditMultiplier without trapping`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Huge Multiplier",
                    modelId: "huge-mult",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local,
            modelCatalog: [
                AntigravityModelCatalogEntry(
                    modelId: "huge-mult",
                    label: "Huge Multiplier",
                    creditMultiplier: 1e30),
                AntigravityModelCatalogEntry(
                    modelId: "normal-mult",
                    label: "Normal Multiplier",
                    creditMultiplier: 1.5),
            ])

        let usage = try snapshot.toUsageSnapshot()
        let catalogSection = try #require(usage.details.first { $0.title == "Model catalog" })
        #expect(catalogSection.rows.count == 2)
        #expect(catalogSection.rows.first { $0.id == "antigravity-catalog-huge-mult" }?.value == "1e+30×")
        #expect(catalogSection.rows.first { $0.id == "antigravity-catalog-normal-mult" }?.value == "1.5×")
    }

    @Test
    func `quota summary drops overflowing remainingAmount without aborting response`() throws {
        let json = """
        {
          "buckets": [
            {
              "bucketId": "gemini-overflow",
              "displayName": "Overflow",
              "refreshWindowLabel": "5h",
              "remainingFraction": 0.65,
              "remainingAmount": "99999999999999999999999"
            },
            {
              "bucketId": "gemini-oneof-overflow",
              "displayName": "Oneof Overflow",
              "refreshWindowLabel": "weekly",
              "remainingFraction": 0.5,
              "remaining": { "case": "remainingAmount", "value": "99999999999999999999999" }
            },
            {
              "bucketId": "3p-valid",
              "displayName": "Valid",
              "refreshWindowLabel": "5h",
              "remainingFraction": 0.8,
              "remainingAmount": "42"
            }
          ]
        }
        """

        let snapshot = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8))
        let buckets = try #require(snapshot.quotaSummary?.groups.first?.buckets)
        #expect(buckets.count == 3)
        #expect(buckets[0].remainingFraction == 0.65)
        #expect(buckets[0].remainingAmount == nil)
        #expect(buckets[1].remainingFraction == 0.5)
        #expect(buckets[1].remainingAmount == nil)
        #expect(buckets[2].remainingAmount == 42)
    }
}

extension AntigravityExtendedMetadataTests {
    @Test
    func `modelCatalogDetailSection deduplicates Premium-only rows and formats multiplier boundaries`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro",
                    modelId: "gemini-3.1-pro",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local,
            modelCatalog: [
                AntigravityModelCatalogEntry(
                    modelId: "premium-only",
                    label: "Premium Only",
                    isPremium: true),
                AntigravityModelCatalogEntry(
                    modelId: "standard-only",
                    label: "Standard Only",
                    isPremium: false),
                AntigravityModelCatalogEntry(
                    modelId: "tagged-premium",
                    label: "Tagged Premium",
                    isPremium: true,
                    tagTitle: "New"),
                AntigravityModelCatalogEntry(
                    modelId: "zero-mult",
                    label: "Zero Mult",
                    creditMultiplier: 0),
                AntigravityModelCatalogEntry(
                    modelId: "quarter-mult",
                    label: "Quarter Mult",
                    creditMultiplier: 1.25),
            ])

        let usage = try snapshot.toUsageSnapshot()
        let catalogSection = try #require(usage.details.first { $0.title == "Model catalog" })
        let byID = Dictionary(uniqueKeysWithValues: catalogSection.rows.map { ($0.id, $0) })

        let premiumOnly = try #require(byID["antigravity-catalog-premium-only"])
        #expect(premiumOnly.value == "Premium")
        #expect(premiumOnly.secondaryValue == nil)

        let standardOnly = try #require(byID["antigravity-catalog-standard-only"])
        #expect(standardOnly.value == "Standard")
        #expect(standardOnly.secondaryValue == nil)

        let taggedPremium = try #require(byID["antigravity-catalog-tagged-premium"])
        #expect(taggedPremium.value == "New")
        #expect(taggedPremium.secondaryValue == "Premium")

        #expect(byID["antigravity-catalog-zero-mult"]?.value == "0×")
        #expect(byID["antigravity-catalog-quarter-mult"]?.value == "1.25×")

        let context = RenderContext(header: "AG", status: nil, useColor: false, resetStyle: .countdown)
        let rendered = CLIRenderer.renderText(
            provider: .antigravity,
            snapshot: usage,
            credits: nil,
            context: context,
            now: Date())
        #expect(rendered.contains("Premium Only: Premium"))
        #expect(!rendered.contains("Premium · Premium"))
    }
}
