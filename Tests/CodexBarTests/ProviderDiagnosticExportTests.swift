import Foundation
import Testing
@testable import CodexBarCore

struct ProviderDiagnosticExportTests {
    @Test
    func `generic diagnostic export encodes safe provider envelope`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let export = ProviderDiagnosticExport(
            timestamp: now,
            provider: "openai",
            displayName: "OpenAI",
            source: "api",
            sourceMode: "auto",
            auth: ProviderDiagnosticAuthSummary(configured: true, modes: ["api"]),
            usage: ProviderDiagnosticUsageSummary(from: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(18000),
                    resetDescription: "raw local text"),
                secondary: nil,
                updatedAt: now)),
            fetchAttempts: [
                ProviderDiagnosticFetchAttempt(
                    kind: "api",
                    wasAvailable: true,
                    errorCategory: nil),
            ],
            error: nil,
            settings: ProviderDiagnosticSettingsSummary(sourceMode: .auto),
            details: nil)

        let json = try self.json(export)

        #expect(json.contains("\"provider\""))
        #expect(json.contains("\"openai\""))
        #expect(json.contains("\"platform\""))
        #expect(json.contains("\"auth\""))
        #expect(json.contains("\"dataConfidence\""))
        #expect(json.contains("\"unknown\""))
        #expect(json.contains("\"hasResetDescription\""))
        #expect(!json.contains("sk-cp-"))
        #expect(!json.contains("sk-api-"))
        #expect(!json.contains("Bearer"))
        #expect(!json.contains("raw local text"))
        #expect(!json.contains("errorMessage"))
        #expect(!json.contains("localizedDescription"))
    }

    @Test
    func `diagnostic export decodes legacy schema without platform metadata`() throws {
        let export = ProviderDiagnosticExport(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "openai",
            displayName: "OpenAI",
            source: "api",
            sourceMode: "auto",
            auth: ProviderDiagnosticAuthSummary(configured: true, modes: ["api"]),
            usage: nil,
            fetchAttempts: [],
            error: nil,
            settings: ProviderDiagnosticSettingsSummary(sourceMode: .auto),
            details: nil)
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(self.json(export).utf8)) as? [String: Any])
        object.removeValue(forKey: "platform")
        object.removeValue(forKey: "appVersion")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ProviderDiagnosticExport.self,
            from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.platform == ProviderDiagnosticPlatform.current)
        #expect(decoded.appVersion == nil)
    }

    @Test
    func `usage snapshot defaults legacy payloads to unknown confidence without reencoding unknown`() throws {
        let json = """
        {
          "primary": {
            "usedPercent": 42,
            "windowMinutes": 300,
            "hasResetDescription": false
          },
          "secondary": null,
          "tertiary": null,
          "updatedAt": "2023-11-14T22:13:20Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.dataConfidence == .unknown)

        let encoded = try self.json(snapshot)
        #expect(!encoded.contains("dataConfidence"))
    }

    @Test
    func `usage snapshot preserves explicit confidence through Codable`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(18000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            dataConfidence: .exact)

        let encoded = try self.json(snapshot)
        #expect(encoded.contains("\"dataConfidence\" : \"exact\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageSnapshot.self, from: Data(encoded.utf8))
        #expect(decoded.dataConfidence == .exact)
    }

    @Test
    func `usage snapshot treats future confidence values as unknown`() throws {
        let json = """
        {
          "primary": null,
          "secondary": null,
          "tertiary": null,
          "updatedAt": "2023-11-14T22:13:20Z",
          "dataConfidence": "future"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.dataConfidence == .unknown)
        #expect(try !self.json(snapshot).contains("dataConfidence"))
    }

    @Test
    func `diagnostic usage summary includes confidence`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ProviderDiagnosticUsageSummary(from: UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(18000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            dataConfidence: .exact))

        #expect(summary.dataConfidence == "exact")
    }

    @Test
    func `diagnostic usage summary defaults legacy payloads to unknown confidence`() throws {
        let json = """
        {
          "updatedAt": "2023-11-14T22:13:20Z",
          "windows": [],
          "extraWindowCount": 0,
          "providerCostPresent": false,
          "providerSpecificData": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(
            ProviderDiagnosticUsageSummary.self,
            from: Data(json.utf8))

        #expect(summary.dataConfidence == "unknown")
        #expect(try self.json(summary).contains("\"dataConfidence\" : \"unknown\""))
    }

    @Test
    func `unwired provider diagnostics remain unknown confidence`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: 1000,
            currentPrompts: 250,
            remainingPrompts: 750,
            windowMinutes: 300,
            usedPercent: 25,
            resetsAt: now.addingTimeInterval(18000),
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()
        let summary = ProviderDiagnosticUsageSummary(from: usage)

        #expect(usage.dataConfidence == .unknown)
        #expect(summary.dataConfidence == "unknown")
        #expect(summary.windows.first?.usedPercent == 25)
    }

    @Test
    func `diagnostic export marks named windows with unknown usage`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ProviderDiagnosticUsageSummary(from: UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "nebula-window",
                    title: "Nebula Window",
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: nil,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil),
                    usageKnown: false),
            ],
            updatedAt: now))

        let json = try self.json(summary)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let windows = try #require(object["windows"] as? [[String: Any]])

        #expect(windows.first?["usageKnown"] as? Bool == false)
    }

    @Test
    func `diagnostic rate window defaults legacy payloads to known usage`() throws {
        let json = """
        {
          "label": "Legacy Window",
          "usedPercent": 42,
          "hasResetDescription": false
        }
        """

        let window = try JSONDecoder().decode(
            ProviderDiagnosticRateWindow.self,
            from: Data(json.utf8))

        #expect(window.usageKnown)
    }

    @Test
    func `raw error text never appears in encoded JSON`() throws {
        let export = ProviderDiagnosticExport(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "minimax",
            displayName: "MiniMax",
            source: "failed",
            sourceMode: "auto",
            auth: ProviderDiagnosticAuthSummary(configured: true, modes: ["api"]),
            usage: nil,
            fetchAttempts: [
                ProviderDiagnosticFetchAttempt(
                    kind: "api",
                    wasAvailable: true,
                    errorCategory: "network"),
            ],
            error: ProviderDiagnosticError(
                category: "network",
                safeDescription: "Network error - check your connection"),
            settings: ProviderDiagnosticSettingsSummary(sourceMode: .auto, apiRegion: "global"),
            details: nil)

        let json = try self.json(export)

        #expect(!json.contains("connection refused"))
        #expect(!json.contains("network probe"))
        #expect(!json.contains("not safe to expose"))
        #expect(!json.contains("localizedDescription"))
        #expect(!json.contains("raw"))
        #expect(!json.contains("errorMessage"))
        #expect(json.contains("errorCategory"))
        #expect(json.contains("\"network\""))
    }

    @Test
    func `diagnostic error maps MiniMaxUsageError categories safely`() {
        let networkError = MiniMaxUsageError.networkError("connection refused")
        let invalidCreds = MiniMaxUsageError.invalidCredentials
        let apiError = MiniMaxUsageError.apiError("HTTP 404")
        let parseError = MiniMaxUsageError.parseFailed("unexpected")

        let diagNetwork = ProviderDiagnosticError(from: networkError, authConfigured: true)
        #expect(diagNetwork.category == "network")
        #expect(!diagNetwork.safeDescription.contains("connection refused"))

        let diagCreds = ProviderDiagnosticError(from: invalidCreds, authConfigured: true)
        #expect(diagCreds.category == "auth")

        let diagAPI = ProviderDiagnosticError(from: apiError, authConfigured: true)
        #expect(diagAPI.category == "api")

        let diagParse = ProviderDiagnosticError(from: parseError, authConfigured: true)
        #expect(diagParse.category == "parse")
    }

    @Test
    func `diagnostic error maps Alibaba invalid endpoint override to configuration`() {
        let error = ProviderEndpointOverrideError.alibabaCodingPlan("ALIBABA_CODING_PLAN_QUOTA_URL")
        let diag = ProviderDiagnosticError(from: error, authConfigured: true)

        #expect(diag.category == "configuration")
        #expect(diag.safeDescription == "Configuration issue - check provider source and settings")
    }

    @Test
    func `endpoint override fetch attempt stays in configuration category`() {
        let error = ProviderEndpointOverrideError.minimax("MINIMAX_HOST")
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.web",
            kind: .web,
            wasAvailable: true,
            errorDescription: error.localizedDescription)

        let diagError = ProviderDiagnosticError(from: error, authConfigured: true)
        let diagAttempt = ProviderDiagnosticFetchAttempt(from: attempt)

        #expect(diagError.category == "configuration")
        #expect(diagAttempt.errorCategory == "configuration")
    }

    @Test
    func `no available strategy maps missing auth to auth category`() {
        let error = ProviderFetchError.noAvailableStrategy(.minimax)
        let diag = ProviderDiagnosticError(from: error, authConfigured: false)

        #expect(diag.category == "auth")
        #expect(diag.safeDescription.contains("Authentication"))
    }

    @Test
    func `available failed strategy does not imply auth is configured`() {
        let outcome = ProviderFetchOutcome(
            result: .failure(ProviderFetchError.noAvailableStrategy(.antigravity)),
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "antigravity.ide-local",
                    kind: .localProbe,
                    wasAvailable: true,
                    errorDescription: "unauthenticated local probe"),
            ])

        let summary = ProviderDiagnosticAuthSummary(configured: false, modes: []).resolved(with: outcome)

        #expect(!summary.configured)
        #expect(summary.modes.isEmpty)
    }

    @Test
    func `fetch attempt error maps to safe category, never raw text`() {
        let attemptWithRawError = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "MiniMax API timeout after 30 seconds - connection refused for host platform.minimax.io")
        let diagAttempt = ProviderDiagnosticFetchAttempt(from: attemptWithRawError)
        #expect(diagAttempt.kind == "api")
        #expect(diagAttempt.wasAvailable == true)
        let errorCategoryOne = diagAttempt.errorCategory
        #expect(errorCategoryOne == "network")
        let cat1 = errorCategoryOne ?? ""
        #expect(!cat1.contains("timeout"))
        #expect(!cat1.contains("connection refused"))
        #expect(!cat1.contains("platform.minimax.io"))

        let attemptWithAuthError = ProviderFetchAttempt(
            strategyID: "minimax.web",
            kind: .web,
            wasAvailable: false,
            errorDescription: "invalid auth token cookie HERTZ-SESSION=abc123")
        let diagAuthAttempt = ProviderDiagnosticFetchAttempt(from: attemptWithAuthError)
        #expect(diagAuthAttempt.wasAvailable == false)
        let errorCategoryTwo = diagAuthAttempt.errorCategory
        #expect(errorCategoryTwo == "auth")
        let cat2 = errorCategoryTwo ?? ""
        #expect(!cat2.contains("HERTZ-SESSION"))
    }

    @Test
    func `missing api key setup errors map to auth before api`() {
        let category = ProviderDiagnosticFetchAttempt.errorCategoryLabel(
            "Azure OpenAI API key not configured. Set AZURE_OPENAI_API_KEY.")

        #expect(category == "auth")
    }

    @Test
    func `MiniMax details map from MiniMaxUsageSnapshot correctly`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: 1000,
            currentPrompts: 250,
            remainingPrompts: 750,
            windowMinutes: 300,
            usedPercent: 25,
            resetsAt: now.addingTimeInterval(18000),
            updatedAt: now,
            services: nil)

        let details = MiniMaxDiagnosticDetails(from: snapshot)
        #expect(details.planName == "Max")
        #expect(details.availablePrompts == 1000)
        #expect(details.currentPrompts == 250)
        #expect(details.remainingPrompts == 750)
        #expect(details.windowMinutes == 300)
        #expect(details.usedPercent == 25)
    }

    @Test
    func `service usage maps from MiniMaxServiceUsage correctly`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = MiniMaxServiceUsage(
            serviceType: "General",
            windowType: "Weekly",
            timeRange: "Jun 15-Jun 22",
            usage: 6,
            limit: 150,
            percent: 4,
            resetsAt: now.addingTimeInterval(18000),
            resetDescription: "Weekly")

        let diagService = MiniMaxDiagnosticServiceUsage(from: service)
        #expect(diagService.displayName == "General")
        #expect(diagService.percent == 4)
        #expect(diagService.usage == 6)
        #expect(diagService.limit == 150)
        #expect(diagService.remaining == 144)
        #expect(diagService.isUnlimited == false)
        #expect(diagService.windowType == "Weekly")
        #expect(diagService.hasResetDescription == true)

        let json = try self.json(diagService)
        #expect(json.contains("hasResetDescription"))
        #expect(json.contains(#""usage" : 6"#))
        #expect(json.contains(#""limit" : 150"#))
        #expect(json.contains(#""remaining" : 144"#))
        #expect(!json.contains("resetDescription"))
    }

    @Test
    func `unlimited MiniMax diagnostic omits remaining quota`() throws {
        let service = MiniMaxServiceUsage(
            serviceType: "General",
            windowType: "Weekly",
            timeRange: "",
            usage: 0,
            limit: 0,
            percent: 0,
            isUnlimited: true,
            resetsAt: nil,
            resetDescription: "Unlimited")

        let diagnostic = MiniMaxDiagnosticServiceUsage(from: service)
        #expect(diagnostic.isUnlimited)
        #expect(diagnostic.remaining == nil)

        let json = try self.json(diagnostic)
        #expect(!json.contains("remaining"))
    }

    @Test
    func `legacy MiniMax service diagnostic decodes without quota values`() throws {
        let data = Data(#"""
        {
          "displayName": "General",
          "percent": 4,
          "windowType": "Weekly",
          "resetsAt": null,
          "hasResetDescription": true
        }
        """#.utf8)

        let diagnostic = try JSONDecoder().decode(MiniMaxDiagnosticServiceUsage.self, from: data)

        #expect(diagnostic.displayName == "General")
        #expect(diagnostic.percent == 4)
        #expect(diagnostic.usage == 0)
        #expect(diagnostic.limit == 0)
        #expect(diagnostic.remaining == nil)
        #expect(!diagnostic.isUnlimited)
        #expect(diagnostic.windowType == "Weekly")
        #expect(diagnostic.hasResetDescription)
    }

    @Test
    func `builder creates generic safe diagnostic with error on failure`() {
        let outcome = ProviderFetchOutcome(
            result: .failure(MiniMaxUsageError.networkError("timeout")),
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "minimax.api",
                    kind: .apiToken,
                    wasAvailable: true,
                    errorDescription: "timeout"),
            ])

        let diag = ProviderDiagnosticExportBuilder.build(.init(
            provider: .minimax,
            descriptor: ProviderDescriptorRegistry.descriptor(for: .minimax),
            outcome: outcome,
            sourceMode: .auto,
            settings: nil,
            auth: ProviderDiagnosticAuthSummary(configured: true, modes: ["apiToken"]),
            appVersion: "9.8.7"))

        #expect(diag.provider == "minimax")
        #expect(diag.platform == ProviderDiagnosticPlatform.current)
        #expect(diag.appVersion == "9.8.7")
        #expect(diag.source == "failed")
        #expect(diag.auth.configured == true)
        #expect(diag.usage == nil)
        #expect(diag.error != nil)
        #expect(diag.error?.category == "network")
        #expect(diag.fetchAttempts.count == 1)
        #expect(diag.fetchAttempts[0].errorCategory == "network")
    }

    @Test
    func `builder creates generic safe diagnostic with MiniMax details on success`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: 1000,
            currentPrompts: 250,
            remainingPrompts: 750,
            windowMinutes: 300,
            usedPercent: 25,
            resetsAt: now.addingTimeInterval(18000),
            updatedAt: now)

        let result = ProviderFetchResult(
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(18000),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                minimaxUsage: snapshot,
                updatedAt: now),
            credits: nil,
            dashboard: nil,
            sourceLabel: "api",
            strategyID: "minimax.api",
            strategyKind: .apiToken)

        let outcome = ProviderFetchOutcome(
            result: .success(result),
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "minimax.api",
                    kind: .apiToken,
                    wasAvailable: true,
                    errorDescription: nil),
            ])

        let diag = ProviderDiagnosticExportBuilder.build(.init(
            provider: .minimax,
            descriptor: ProviderDescriptorRegistry.descriptor(for: .minimax),
            outcome: outcome,
            sourceMode: .auto,
            settings: nil,
            auth: ProviderDiagnosticAuthSummary(configured: true, modes: ["apiToken"])))

        #expect(diag.provider == "minimax")
        #expect(diag.source == "api")
        #expect(diag.auth.configured == true)
        #expect(diag.usage != nil)
        #expect(diag.error == nil)

        guard case let .minimax(details) = diag.details else {
            Issue.record("Expected MiniMax diagnostic details")
            return
        }
        #expect(details.planName == "Max")
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
