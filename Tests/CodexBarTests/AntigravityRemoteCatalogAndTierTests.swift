import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct AntigravityRemoteCatalogAndTierTests {
    @Test
    func `loadCodeAssist maps g1 tier IDs and paidTier manageSubscriptionUri fallback`() async throws {
        struct Scenario {
            let loadCodeAssistBody: [String: Any]
            let expectedPlan: String?
            let expectedManageURI: String?
        }

        let scenarios: [Scenario] = [
            Scenario(
                loadCodeAssistBody: ["paidTier": ["id": "g1-ultra-tier"]],
                expectedPlan: "Google AI Ultra",
                expectedManageURI: nil),
            Scenario(
                loadCodeAssistBody: [
                    "g1Tier": "G1_ULTRA_TIER",
                    "paidTier": ["id": "g1-ultra-tier", "name": "Pro"],
                ],
                expectedPlan: "Google AI Ultra",
                expectedManageURI: nil),
            Scenario(
                loadCodeAssistBody: [
                    "g1Tier": "G1_ULTRA_TIER",
                    "paidTier": ["id": "g1-ultra-tier", "name": "Google AI Pro"],
                ],
                expectedPlan: "Google AI Ultra",
                expectedManageURI: nil),
            Scenario(
                loadCodeAssistBody: [
                    "g1Tier": "G1_ULTRA_TIER",
                    "paidTier": ["name": "Google AI Pro"],
                ],
                expectedPlan: "Google AI Ultra",
                expectedManageURI: nil),
            Scenario(
                loadCodeAssistBody: [
                    "g1Tier": "GOOGLE_ONE_HELIUM",
                    "currentTier": ["id": "standard-tier"],
                ],
                expectedPlan: "Google AI Ultra",
                expectedManageURI: nil),
            Scenario(
                loadCodeAssistBody: [
                    "paidTier": [
                        "id": "g1-ultra-lite-tier",
                        "manageSubscriptionUri": "https://one.google.com/manage",
                    ],
                ],
                expectedPlan: "Google AI Ultra Lite",
                expectedManageURI: "https://one.google.com/manage"),
            Scenario(
                loadCodeAssistBody: ["paidTier": ["id": "g1-plus-tier"]],
                expectedPlan: "Google AI Plus",
                expectedManageURI: nil),
        ]

        for scenario in scenarios {
            let env = try GeminiTestEnvironment()
            defer { env.cleanup() }
            try env.writeAntigravityCredentials(
                accessToken: "token",
                refreshToken: nil,
                expiry: Date().addingTimeInterval(3600),
                email: "tier@example.com",
                projectID: "proj-tier")
            let loadCodeAssistData = GeminiAPITestHelpers.jsonData(scenario.loadCodeAssistBody)
            let dataLoader = GeminiAPITestHelpers.dataLoader { request in
                let url = try #require(request.url)
                switch url.path {
                case "/v1internal:loadCodeAssist":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: loadCodeAssistData)
                case "/v1internal:retrieveUserQuotaSummary":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "groups": [[
                                "displayName": "Gemini Models",
                                "buckets": [[
                                    "bucketId": "gemini-weekly",
                                    "window": "weekly",
                                    "remainingFraction": 0.75,
                                ]],
                            ]],
                        ]))
                default:
                    throw URLError(.unsupportedURL)
                }
            }
            let snapshot = try await AntigravityRemoteUsageFetcher(
                timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader).fetch()
            #expect(snapshot.accountPlan == scenario.expectedPlan)
            #expect(snapshot.accountMetadata?.manageSubscriptionURI == scenario.expectedManageURI)
        }
    }

    @Test
    func `fallback retrieveUserQuota preserves remainingAmount on modelQuotas and catalog`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            email: "fallback@example.com",
            projectID: "proj-fallback")
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["currentTier": ["id": "standard-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary", "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 403,
                    body: Data("denied".utf8))
            case "/v1internal:retrieveUserQuota":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "buckets": [[
                            "modelId": "gemini-3-pro-low",
                            "remainingFraction": 0.4,
                            "remainingAmount": "120",
                            "resetTime": "2026-12-01T00:00:00Z",
                        ]],
                    ]))
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader).fetch()
        #expect(snapshot.modelQuotas.first?.remainingAmount == 120)
        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 120)
        #expect(usage.details.first { $0.title == "Bucket amounts" }?.rows.first?.value == "120 remaining")
    }

    @Test
    func `primary quota summary enriches modelCatalog best effort and rethrows cancellation`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            email: "catalog@example.com",
            projectID: "proj-catalog")

        let enrichedLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
                    ]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [[
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.7,
                            ]],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "models": [
                            "gemini-3-pro": [
                                "displayName": "Gemini 3 Pro",
                                "creditMultiplier": 1.5,
                                "pricingType": "MODEL_PRICING_TYPE_STATIC_CREDIT",
                                "isPremium": true,
                                "tagTitle": "New",
                            ],
                            "claude-opus-4-6": [
                                "label": "Claude Opus 4.6",
                                "credit_multiplier": "2.0",
                                "pricing_type": 2,
                                "premium": true,
                                "tag_title": "Thinking",
                            ],
                        ],
                    ]))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: enrichedLoader).fetch()
        #expect(snapshot.modelCatalog.count == 2)
        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.antigravityCatalog?.modelCatalog?.first { $0.modelId == "claude-opus-4-6" }
            == AntigravityModelCatalogEntry(
                modelId: "claude-opus-4-6",
                label: "Claude Opus 4.6",
                creditMultiplier: 2.0,
                pricingType: "MODEL_PRICING_TYPE_API",
                isPremium: true,
                tagTitle: "Thinking"))
        #expect(usage.details.contains { $0.title == "Model catalog" })

        let failingCatalogLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["paidTier": ["id": "g1-pro-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [[
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.7,
                            ]],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let resilientSnapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: failingCatalogLoader).fetch()
        #expect(resilientSnapshot.modelCatalog.isEmpty)
        #expect(resilientSnapshot.accountPlan == "Google AI Pro")

        let cancelledCatalogLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["paidTier": ["id": "g1-pro-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [[
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.7,
                            ]],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                throw CancellationError()
            default:
                throw URLError(.unsupportedURL)
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await AntigravityRemoteUsageFetcher(
                timeout: 1, homeDirectory: env.homeURL.path, dataLoader: cancelledCatalogLoader).fetch()
        }
    }

    @Test
    func `fetchAvailableModels drops malformed creditMultiplier across primary and fallback paths`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            email: "resilient-remote@example.com",
            projectID: "proj-resilient")

        let primaryLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["paidTier": ["id": "g1-ultra-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [[
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.7,
                            ]],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "models": [
                            "gemini-3-pro": [
                                "displayName": "Gemini 3 Pro",
                                "creditMultiplier": "1.5",
                            ],
                            "gemini-3-nan": [
                                "displayName": "Gemini 3 NaN",
                                "creditMultiplier": "NaN",
                                "pricingType": "MODEL_PRICING_TYPE_API",
                            ],
                            "gemini-3-inf": [
                                "displayName": "Gemini 3 Inf",
                                "creditMultiplier": "Infinity",
                            ],
                            "gemini-3-bad": [
                                "displayName": "Gemini 3 Bad",
                                "creditMultiplier": "not-a-number",
                            ],
                        ],
                    ]))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let primarySnapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: primaryLoader).fetch()
        #expect(primarySnapshot.modelCatalog.count == 2)
        #expect(primarySnapshot.modelCatalog.first { $0.modelId == "gemini-3-pro" }?.creditMultiplier == 1.5)
        let nanEntry = try #require(primarySnapshot.modelCatalog.first { $0.modelId == "gemini-3-nan" })
        #expect(nanEntry.creditMultiplier == nil)
        #expect(nanEntry.pricingType == "MODEL_PRICING_TYPE_API")

        let fallbackLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["paidTier": ["id": "g1-pro-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            case "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "models": [
                            "gemini-3-pro": [
                                "displayName": "Gemini 3 Pro",
                                "creditMultiplier": "1.5",
                                "quotaInfo": ["remainingFraction": 0.5],
                            ],
                            "gemini-3-nan": [
                                "displayName": "Gemini 3 NaN",
                                "creditMultiplier": "NaN",
                                "quotaInfo": ["remainingFraction": 0.4],
                            ],
                        ],
                    ]))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let fallbackSnapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: fallbackLoader).fetch()
        #expect(fallbackSnapshot.modelQuotas.count == 2)
        #expect(fallbackSnapshot.modelCatalog.count == 1)
        #expect(fallbackSnapshot.modelCatalog.first?.modelId == "gemini-3-pro")
        #expect(fallbackSnapshot.modelCatalog.first?.creditMultiplier == 1.5)
    }

    @Test
    func `fallback retrieveUserQuota drops overflowing remainingAmount without aborting response`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            email: "overflow-fallback@example.com",
            projectID: "proj-overflow")
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["currentTier": ["id": "standard-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary", "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 403,
                    body: Data("denied".utf8))
            case "/v1internal:retrieveUserQuota":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "buckets": [[
                            "modelId": "gemini-3-pro-low",
                            "remainingFraction": 0.4,
                            "remainingAmount": "99999999999999999999999",
                        ]],
                    ]))
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader).fetch()
        #expect(snapshot.modelQuotas.count == 1)
        #expect(snapshot.modelQuotas.first?.remainingFraction == 0.4)
        #expect(snapshot.modelQuotas.first?.remainingAmount == nil)
    }

    @Test
    func `free tier with 5h bucket strips free plan while preserving modelCatalog credits and bucketAmounts`()
        async throws
    {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            email: "free-tier@example.com",
            projectID: "proj-free")

        let loader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "currentTier": [
                            "id": "free-tier",
                            "name": "Free",
                            "availableCredits": [[
                                "creditType": "GOOGLE_ONE_AI",
                                "creditAmount": "75",
                            ]],
                        ],
                    ]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [
                                [
                                    "bucketId": "gemini-5h",
                                    "window": "5h",
                                    "remainingFraction": 0.6,
                                    "remainingAmount": "120",
                                ],
                                [
                                    "bucketId": "gemini-weekly",
                                    "window": "weekly",
                                    "remainingFraction": 0.8,
                                    "remainingAmount": "400",
                                ],
                            ],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "models": [
                            "gemini-3.1-pro": [
                                "displayName": "Gemini 3.1 Pro",
                                "creditMultiplier": 1.5,
                                "isPremium": true,
                            ],
                        ],
                    ]))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: loader).fetch()
        #expect(snapshot.accountPlan == nil)
        #expect(snapshot.modelCatalog.map(\.modelId) == ["gemini-3.1-pro"])
        #expect(snapshot.credits?.availableCredits?.first?.creditAmount == 75)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.identity?.loginMethod == nil)
        #expect(usage.antigravityCatalog?.modelCatalog?.map(\.modelId) == ["gemini-3.1-pro"])
        #expect(usage.antigravityCatalog?.bucketAmounts?.map(\.remainingAmount) == [120, 400])
        #expect(usage.antigravityCredits?.availableCredits?.first?.creditAmount == 75)
    }

    @Test
    func `fetchAvailableModels HTTP 401 degrades cleanly while CancellationError still propagates`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            email: "401-catalog@example.com",
            projectID: "proj-401")

        let unauthorizedCatalogLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["paidTier": ["id": "g1-pro-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [[
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.7,
                            ]],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1, homeDirectory: env.homeURL.path, dataLoader: unauthorizedCatalogLoader).fetch()
        #expect(snapshot.accountPlan == "Google AI Pro")
        #expect(snapshot.modelCatalog.isEmpty)
        #expect(snapshot.hasKnownQuotaSummary)

        let cancelledCatalogLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["paidTier": ["id": "g1-pro-tier"]]))
            case "/v1internal:retrieveUserQuotaSummary":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "groups": [[
                            "displayName": "Gemini Models",
                            "buckets": [[
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.7,
                            ]],
                        ]],
                    ]))
            case "/v1internal:fetchAvailableModels":
                throw CancellationError()
            default:
                throw URLError(.unsupportedURL)
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await AntigravityRemoteUsageFetcher(
                timeout: 1, homeDirectory: env.homeURL.path, dataLoader: cancelledCatalogLoader).fetch()
        }
    }
}
