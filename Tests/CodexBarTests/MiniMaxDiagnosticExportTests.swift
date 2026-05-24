import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxDiagnosticExportTests {
    @Test
    func `diagnostic export encodes to JSON with all safe fields`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let export = MiniMaxDiagnosticExport(
            timestamp: now,
            provider: "minimax",
            source: "api",
            authMode: "apiToken",
            authConfigured: true,
            usage: MiniMaxDiagnosticUsage(
                planName: "Max",
                availablePrompts: 1000,
                currentPrompts: 250,
                remainingPrompts: 750,
                windowMinutes: 300,
                usedPercent: 25,
                resetsAt: now.addingTimeInterval(18000),
                services: nil),
            fetchAttempts: [
                MiniMaxDiagnosticFetchAttempt(
                    strategyID: "minimax.api",
                    kind: "api",
                    wasAvailable: true,
                    errorMessage: nil),
            ],
            error: nil,
            settingsSummary: MiniMaxSettingsSummary(
                cookieSource: "auto",
                apiRegion: "global",
                authMode: "apiToken"))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(export)
        let json = String(data: data, encoding: .utf8) ?? ""

        #expect(json.contains("\"provider\""))
        #expect(json.contains("\"minimax\""))
        #expect(json.contains("\"authConfigured\""))
        #expect(!json.contains("sk-cp-"))
        #expect(!json.contains("sk-api-"))
        #expect(!json.contains("Bearer"))
    }

    @Test
    func `diagnostic error maps MiniMaxUsageError categories safely`() {
        let networkError = MiniMaxUsageError.networkError("connection refused")
        let invalidCreds = MiniMaxUsageError.invalidCredentials
        let apiError = MiniMaxUsageError.apiError("HTTP 404")
        let parseError = MiniMaxUsageError.parseFailed("unexpected")

        let diagNetwork = MiniMaxDiagnosticError(from: networkError)
        #expect(diagNetwork.category == "network")
        #expect(!diagNetwork.safeDescription.contains("connection refused"))

        let diagCreds = MiniMaxDiagnosticError(from: invalidCreds)
        #expect(diagCreds.category == "auth")

        let diagAPI = MiniMaxDiagnosticError(from: apiError)
        #expect(diagAPI.category == "api")

        let diagParse = MiniMaxDiagnosticError(from: parseError)
        #expect(diagParse.category == "parse")
    }

    @Test
    func `diagnostic error maps MiniMaxSettingsError categories safely`() {
        let missingCookie = MiniMaxSettingsError.missingCookie
        let diag = MiniMaxDiagnosticError(from: missingCookie)
        #expect(diag.category == "auth")
        #expect(diag.safeDescription.contains("Cookie"))
    }

    @Test
    func `diagnostic fetch attempt serializes kind correctly`() {
        let webAttempt = ProviderFetchAttempt(
            strategyID: "minimax.web",
            kind: .web,
            wasAvailable: true,
            errorDescription: nil)
        let diagAttempt = MiniMaxDiagnosticFetchAttempt(from: webAttempt)
        #expect(diagAttempt.kind == "web")
        #expect(diagAttempt.strategyID == "minimax.web")

        let apiAttempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: false,
            errorDescription: "token missing")
        let diagApiAttempt = MiniMaxDiagnosticFetchAttempt(from: apiAttempt)
        #expect(diagApiAttempt.kind == "api")
        #expect(diagApiAttempt.wasAvailable == false)
        #expect(diagApiAttempt.errorMessage == "token missing")
    }

    @Test
    func `usage maps from MiniMaxUsageSnapshot correctly`() {
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

        let diagUsage = MiniMaxDiagnosticUsage(from: snapshot)
        #expect(diagUsage.planName == "Max")
        #expect(diagUsage.availablePrompts == 1000)
        #expect(diagUsage.currentPrompts == 250)
        #expect(diagUsage.remainingPrompts == 750)
        #expect(diagUsage.windowMinutes == 300)
        #expect(diagUsage.usedPercent == 25)
    }

    @Test
    func `service usage maps from MiniMaxServiceUsage correctly`() {
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
    }

    @Test
    func `builder creates safe diagnostic with error on failure`() {
        let error = MiniMaxUsageError.networkError("timeout")
        let outcome = ProviderFetchOutcome(
            result: .failure(error),
            attempts: [
                ProviderFetchAttempt(
                    strategyID: "minimax.api",
                    kind: .apiToken,
                    wasAvailable: true,
                    errorDescription: "timeout"),
            ])

        let diag = MiniMaxDiagnosticExportBuilder.build(
            outcome: outcome,
            settings: nil,
            authMode: .apiToken)

        #expect(diag.provider == "minimax")
        #expect(diag.source == "failed")
        #expect(diag.authConfigured == true)
        #expect(diag.usage == nil)
        #expect(diag.error != nil)
        #expect(diag.error?.category == "network")
        #expect(diag.fetchAttempts.count == 1)
    }

    @Test
    func `builder creates safe diagnostic with usage on success`() {
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

        let diag = MiniMaxDiagnosticExportBuilder.build(
            outcome: outcome,
            settings: nil,
            authMode: .apiToken)

        #expect(diag.provider == "minimax")
        #expect(diag.source == "api")
        #expect(diag.authConfigured == true)
        #expect(diag.usage != nil)
        #expect(diag.usage?.planName == "Max")
        #expect(diag.error == nil)
    }
}
