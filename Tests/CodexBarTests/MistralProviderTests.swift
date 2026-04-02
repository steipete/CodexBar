import Foundation
import Testing
@testable import CodexBarCore

struct MistralSettingsReaderTests {
    @Test
    func `api key reads from environment`() {
        let token = MistralSettingsReader.apiKey(environment: ["MISTRAL_API_KEY": "mistral-test-key"])
        #expect(token == "mistral-test-key")
    }

    @Test
    func `api key strips surrounding quotes`() {
        let token = MistralSettingsReader.apiKey(environment: ["MISTRAL_API_KEY": "\"mistral-test-key\""])
        #expect(token == "mistral-test-key")
    }

    @Test
    func `api URL supports overrides`() {
        let url = MistralSettingsReader.apiURL(environment: ["MISTRAL_API_URL": "https://proxy.example/v1"])
        #expect(url.absoluteString == "https://proxy.example/v1")
    }
}

struct MistralUsageSnapshotTests {
    @Test
    func `parses documented model list response shape`() throws {
        let data = Data(
            """
            {
              "object": "list",
              "data": [
                {
                  "id": "mistral-medium-2508",
                  "object": "model",
                  "created": 1775089283,
                  "owned_by": "mistralai",
                  "capabilities": {
                    "completion_chat": true,
                    "function_calling": true,
                    "reasoning": false,
                    "completion_fim": false,
                    "fine_tuning": true,
                    "vision": true,
                    "ocr": false,
                    "classification": false,
                    "moderation": false,
                    "audio": false,
                    "audio_transcription": false,
                    "audio_transcription_realtime": false,
                    "audio_speech": false
                  },
                  "name": "mistral-medium-2508",
                  "description": "Update on Mistral Medium 3 with improved capabilities.",
                  "max_context_length": 131072,
                  "aliases": ["mistral-medium-latest", "mistral-medium"],
                  "deprecation": null,
                  "deprecation_replacement_model": null,
                  "default_model_temperature": 0.3,
                  "type": "base"
                }
              ]
            }
            """.utf8)

        let response = try MistralFetcher.parseModelListResponse(data: data)

        #expect(response.object == "list")
        #expect(response.data.count == 1)
        #expect(response.data.first?.id == "mistral-medium-2508")
        #expect(response.data.first?.capabilities.functionCalling == true)
        #expect(response.data.first?.aliases == ["mistral-medium-latest", "mistral-medium"])
    }

    @Test
    func `maps rate limit windows into usage snapshot`() {
        let requests = MistralRateLimitWindow(
            kind: "requests",
            limit: 120,
            remaining: 30,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: "Requests: 30/120")
        let tokens = MistralRateLimitWindow(
            kind: "tokens",
            limit: 1000,
            remaining: 400,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_600),
            resetDescription: "Tokens: 400/1000")
        let model = MistralModelCard(
            id: "codestral-latest",
            object: "model",
            created: nil,
            ownedBy: "workspace-123",
            capabilities: MistralModelCapabilities(
                completionChat: true,
                completionFim: true,
                functionCalling: false,
                fineTuning: false,
                vision: false,
                ocr: false,
                classification: false,
                moderation: false,
                audio: false,
                audioTranscription: false),
            name: "Codestral",
            description: nil,
            maxContextLength: 262_144,
            aliases: [],
            deprecation: nil,
            deprecationReplacementModel: nil,
            defaultModelTemperature: nil,
            type: "base",
            job: nil,
            root: nil,
            archived: false)
        let snapshot = MistralUsageSnapshot(
            models: [model],
            rateLimits: MistralRateLimitSnapshot(
                requests: requests,
                tokens: tokens,
                retryAfter: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 75)
        #expect(usage.secondary?.usedPercent == 60)
        #expect(usage.accountOrganization(for: .mistral) == "workspace-123")
        #expect(usage.loginMethod(for: .mistral)?.contains("Codestral") == true)
    }

    @Test
    func `deduplicates preview model names while preserving total model count`() {
        let models = [
            MistralModelCard(
                id: "mistral-medium-2508",
                object: "model",
                created: nil,
                ownedBy: "mistralai",
                capabilities: MistralModelCapabilities(completionChat: true),
                name: "mistral-medium-2508",
                description: nil,
                maxContextLength: nil,
                aliases: [],
                deprecation: nil,
                deprecationReplacementModel: nil,
                defaultModelTemperature: nil,
                type: "base",
                job: nil,
                root: nil,
                archived: false),
            MistralModelCard(
                id: "mistral-medium-latest",
                object: "model",
                created: nil,
                ownedBy: "mistralai",
                capabilities: MistralModelCapabilities(completionChat: true),
                name: "mistral-medium-2508",
                description: nil,
                maxContextLength: nil,
                aliases: [],
                deprecation: nil,
                deprecationReplacementModel: nil,
                defaultModelTemperature: nil,
                type: "base",
                job: nil,
                root: nil,
                archived: false),
            MistralModelCard(
                id: "codestral-latest",
                object: "model",
                created: nil,
                ownedBy: "workspace-123",
                capabilities: MistralModelCapabilities(completionChat: true, completionFim: true),
                name: "Codestral",
                description: nil,
                maxContextLength: nil,
                aliases: [],
                deprecation: nil,
                deprecationReplacementModel: nil,
                defaultModelTemperature: nil,
                type: "base",
                job: nil,
                root: nil,
                archived: false,
            )
        ]

        let snapshot = MistralUsageSnapshot(models: models, rateLimits: nil, updatedAt: .distantPast)

        #expect(snapshot.modelCount == 3)
        #expect(snapshot.accessibleModelNames == ["mistral-medium-2508", "Codestral"])
        #expect(snapshot.loginSummary == "3 models")
    }
}

struct MistralSharedIntegrationTests {
    @Test
    func `provider settings snapshot keeps mistral hybrid cookie settings`() {
        let snapshot = ProviderSettingsSnapshot.make(
            mistral: ProviderSettingsSnapshot.MistralProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "ory_session=abc; csrftoken=def"))

        #expect(snapshot.mistral?.cookieSource == .manual)
        #expect(snapshot.mistral?.manualCookieHeader == "ory_session=abc; csrftoken=def")
        #expect(snapshot.mistral?.prefersAPIInAuto == false)
    }

    @Test
    func `provider settings builder applies mistral contribution`() {
        var builder = ProviderSettingsSnapshotBuilder()
        builder.apply(
            .mistral(
                ProviderSettingsSnapshot.MistralProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                ))
        )

        let snapshot = builder.build()

        #expect(snapshot.mistral?.cookieSource == .auto)
        #expect(snapshot.mistral?.manualCookieHeader == nil)
        #expect(snapshot.mistral?.prefersAPIInAuto == false)
    }

    @Test
    func `mistral token account snapshots prefer api in auto mode`() {
        let snapshot = ProviderSettingsSnapshot.make(
            mistral: ProviderSettingsSnapshot.MistralProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil,
                prefersAPIInAuto: true))

        #expect(snapshot.mistral?.prefersAPIInAuto == true)
    }

    @Test
    func `usage snapshot round trips persisted mistral monthly summary`() throws {
        let summary = MistralUsageSummarySnapshot(
            sourceKind: .web,
            modelCount: 3,
            previewModelNames: "codestral-latest, mistral-medium-latest",
            workspaceSummary: "workspace-123",
            totalCost: 12.34,
            currencyCode: "USD",
            currencySymbol: "$",
            totalInputTokens: 1000,
            totalOutputTokens: 500,
            totalCachedTokens: 250,
            periodStart: Date(timeIntervalSince1970: 1_796_083_200),
            periodEnd: Date(timeIntervalSince1970: 1_798_761_599),
            workspaces: [],
        )
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                resetDescription: "Monthly"),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 12.34,
                limit: 50,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_799_000_000)),
            mistralUsage: summary,
            updatedAt: Date(timeIntervalSince1970: 1_799_000_100),
            identity: ProviderIdentitySnapshot(
                providerID: .mistral,
                accountEmail: nil,
                accountOrganization: "workspace-123",
                loginMethod: "Connected"))

        let encoded = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)

        #expect(decoded.mistralUsage == summary)
        #expect(decoded.mistralUsage?.sourceKind == .web)
        #expect(decoded.mistralUsage?.totalTokens == 1750)
        #expect(decoded.mistralUsage?.billingPeriodLabel != nil)
        #expect(decoded.providerCost?.used == 12.34)
        #expect(decoded.accountOrganization(for: .mistral) == "workspace-123")
    }
}
