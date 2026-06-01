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
        #expect(json.contains("\"auth\""))
        #expect(json.contains("\"hasResetDescription\""))
        #expect(!json.contains("sk-cp-"))
        #expect(!json.contains("sk-api-"))
        #expect(!json.contains("Bearer"))
        #expect(!json.contains("raw local text"))
        #expect(!json.contains("errorMessage"))
        #expect(!json.contains("localizedDescription"))
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
                    strategyID: "antigravity.local",
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
    func `invalid provider endpoint overrides map to configuration diagnostics`() {
        let alibaba = ProviderDiagnosticError(
            from: AlibabaCodingPlanSettingsError.invalidEndpointOverride(AlibabaCodingPlanSettingsReader.quotaURLKey),
            authConfigured: true)
        #expect(alibaba.category == "configuration")
        #expect(alibaba.safeDescription == "Configuration issue - check provider source and settings")

        let minimax = ProviderDiagnosticError(
            from: MiniMaxSettingsError.invalidEndpointOverride(MiniMaxSettingsReader.remainsURLKey),
            authConfigured: true)
        #expect(minimax.category == "configuration")
        #expect(minimax.safeDescription == "Configuration issue - check provider source and settings")
    }

    @Test
    func `invalid endpoint override fetch attempt text maps to configuration before auth or api`() {
        let alibabaDescription = AlibabaCodingPlanSettingsError
            .invalidEndpointOverride(AlibabaCodingPlanSettingsReader.quotaURLKey)
            .localizedDescription
        let minimaxDescription = MiniMaxSettingsError
            .invalidEndpointOverride(MiniMaxSettingsReader.remainsURLKey)
            .localizedDescription

        #expect(ProviderDiagnosticFetchAttempt.errorCategoryLabel(alibabaDescription) == "configuration")
        #expect(ProviderDiagnosticFetchAttempt.errorCategoryLabel(minimaxDescription) == "configuration")
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
            serviceType: "Text Generation",
            windowType: "5 hours",
            timeRange: "10:00-15:00(UTC+8)",
            usage: 750,
            limit: 1000,
            percent: 75,
            resetsAt: now.addingTimeInterval(18000),
            resetDescription: "5 hours")

        let diagService = MiniMaxDiagnosticServiceUsage(from: service)
        #expect(diagService.displayName == "Text Generation")
        #expect(diagService.percent == 75)
        #expect(diagService.windowType == "5 hours")
        #expect(diagService.hasResetDescription == true)

        let json = try self.json(diagService)
        #expect(json.contains("hasResetDescription"))
        #expect(!json.contains("resetDescription"))
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
            auth: ProviderDiagnosticAuthSummary(configured: true, modes: ["apiToken"])))

        #expect(diag.provider == "minimax")
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
