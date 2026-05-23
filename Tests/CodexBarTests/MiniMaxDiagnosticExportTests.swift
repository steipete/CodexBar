import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct MiniMaxDiagnosticExportTests {
    // MARK: - Auth mode and region

    @Test
    func `export captures auth mode apiToken`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: 1000,
            currentPrompts: 250,
            remainingPrompts: 750,
            windowMinutes: 300,
            usedPercent: 25,
            resetsAt: nil,
            updatedAt: Date())

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: .global,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.authMode == "apiToken")
    }

    @Test
    func `export captures auth mode webSession`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.web")
        let snapshot = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: Date())

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: .chinaMainland,
            authMode: "webSession",
            snapshot: snapshot)

        #expect(export.authMode == "webSession")
        #expect(export.region == "cn")
    }

    @Test
    func `export captures region global`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = Self.makeEmptySnapshot()

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: .global,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.region == "global")
    }

    @Test
    func `export captures region chinaMainland`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = Self.makeEmptySnapshot()

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: .chinaMainland,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.region == "cn")
    }

    @Test
    func `export captures nil region when unknown`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = Self.makeEmptySnapshot()

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.region == nil)
    }

    // MARK: - Field presence

    @Test
    func `fieldsPresent includes planName when non-nil`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Pro",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: Date())

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.fieldsPresent.contains("planName"))
    }

    @Test
    func `fieldsPresent excludes planName when nil`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = Self.makeEmptySnapshot()

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.fieldsPresent.contains("planName") == false)
    }

    @Test
    func `fieldsPresent includes services when non-nil`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let service = MiniMaxServiceUsage(
            serviceType: "text-generation",
            windowType: "5 hours",
            timeRange: "10:00-15:00(UTC+8)",
            usage: 100,
            limit: 1000,
            percent: 10,
            resetsAt: nil,
            resetDescription: "Resets in 5 hours")
        let snapshot = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: Date(),
            services: [service])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.fieldsPresent.contains("services"))
    }

    @Test
    func `servicesCount reflects services length`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let service1 = MiniMaxServiceUsage(
            serviceType: "text-generation",
            windowType: "5 hours",
            timeRange: "10:00-15:00",
            usage: 100,
            limit: 1000,
            percent: 10,
            resetsAt: nil,
            resetDescription: "Resets in 5 hours")
        let service2 = MiniMaxServiceUsage(
            serviceType: "image",
            windowType: "Today",
            timeRange: "00:00-23:59",
            usage: 50,
            limit: 500,
            percent: 10,
            resetsAt: nil,
            resetDescription: "Resets at midnight")
        let snapshot = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: Date(),
            services: [service1, service2])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.servicesCount == 2)
    }

    @Test
    func `billingSummaryPresent true when billingSummary non-nil`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let billing = MiniMaxBillingSummary(
            todayTokens: 1000,
            last30DaysTokens: 50000,
            todayCash: 0.05,
            last30DaysCash: 2.50,
            daily: [],
            topMethods: [],
            topModels: [],
            updatedAt: Date())
        let snapshot = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: Date(),
            billingSummary: billing)

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.billingSummaryPresent == true)
    }

    @Test
    func `billingSummaryPresent false when billingSummary nil`() {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = Self.makeEmptySnapshot()

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: snapshot)

        #expect(export.billingSummaryPresent == false)
    }

    // MARK: - Fetch attempt categorization

    @Test
    func `fetch attempt 401 maps to auth`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "HTTP 401 Unauthorized: invalid token sk-cp-secret")
        let outcome = ProviderFetchOutcome(result: .failure(MiniMaxUsageError.invalidCredentials), attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary.count == 1)
        #expect(export.fetchAttemptsSummary[0].errorCategory == .auth)
    }

    @Test
    func `fetch attempt 403 maps to auth`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "HTTP/1.1 403 Forbidden - access denied")
        let outcome = ProviderFetchOutcome(result: .failure(MiniMaxUsageError.invalidCredentials), attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].errorCategory == .auth)
    }

    @Test
    func `bounded 401 maps to auth`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "response status 401 and request failed")
        let outcome = ProviderFetchOutcome(result: .failure(MiniMaxUsageError.invalidCredentials), attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].errorCategory == .auth)
        #expect(export.fetchAttemptsSummary[0].errorCode == "401")
    }

    @Test
    func `embedded 401 digits do not map to auth`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "service status_code=1401 and retrying")
        let outcome = ProviderFetchOutcome(
            result: .failure(MiniMaxUsageError.parseFailed("bad response")),
            attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].errorCategory == .unknown)
        #expect(export.fetchAttemptsSummary[0].errorCode == nil)
    }

    @Test
    func `overlong status code does not map to auth`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "HTTP 2000 from proxy")
        let outcome = ProviderFetchOutcome(
            result: .failure(MiniMaxUsageError.parseFailed("bad response")),
            attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].errorCategory == .unknown)
        #expect(export.fetchAttemptsSummary[0].errorCode == nil)
    }

    @Test
    func `timeout maps to timeout`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.web",
            kind: .web,
            wasAvailable: true,
            errorDescription: "Request timed out after 60 seconds")
        let outcome = ProviderFetchOutcome(
            result: .failure(MiniMaxUsageError.networkError("timed out")),
            attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "webSession",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].errorCategory == .timeout)
    }

    @Test
    func `unknown error maps to unknown`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "Something went wrong")
        let outcome = ProviderFetchOutcome(
            result: .failure(MiniMaxUsageError.parseFailed("unknown")),
            attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].errorCategory == .unknown)
    }

    @Test
    func `fetch attempt wasAvailable true has no error`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: nil)
        let outcome = ProviderFetchOutcome(
            result: .success(Self.makeSuccessResult(strategyID: "minimax.api")),
            attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.fetchAttemptsSummary[0].wasAvailable == true)
        #expect(export.fetchAttemptsSummary[0].errorCode == nil)
        #expect(export.fetchAttemptsSummary[0].errorCategory == .unknown)
    }

    @Test
    func `empty fetch attempts produces valid export`() {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: false,
            errorDescription: nil)
        let outcome = ProviderFetchOutcome(result: .failure(MiniMaxUsageError.invalidCredentials), attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        #expect(export.schemaVersion == "1.0")
        #expect(export.provider == .minimax)
        #expect(export.fetchAttemptsSummary.count == 1)
    }

    // MARK: - JSON serialization

    @Test
    func `serialized diagnostic JSON contains no raw token strings`() throws {
        let attempt = ProviderFetchAttempt(
            strategyID: "minimax.api",
            kind: .apiToken,
            wasAvailable: true,
            errorDescription: "401 Unauthorized: Bearer sk-cp-faketoken and user@test.com")
        let outcome = ProviderFetchOutcome(
            result: .success(Self.makeSuccessResult(strategyID: "minimax.api")),
            attempts: [attempt])

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: nil,
            authMode: "apiToken",
            snapshot: nil)

        let jsonData = try JSONEncoder().encode(export)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

        #expect(jsonString.contains("sk-cp-") == false)
        #expect(jsonString.contains("faketoken") == false)
        #expect(jsonString.contains("user@test.com") == false)
        #expect(jsonString.contains("401"))
    }

    @Test
    func `json roundtrip preserves all fields`() throws {
        let outcome = Self.makeSuccessOutcome(strategyID: "minimax.api")
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Pro",
            availablePrompts: 1000,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: 300,
            usedPercent: 10,
            resetsAt: nil,
            updatedAt: Date())

        let export = MiniMaxDiagnosticExportBuilder.build(
            from: outcome,
            region: .global,
            authMode: "apiToken",
            snapshot: snapshot)

        let jsonData = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(MiniMaxDiagnosticExport.self, from: jsonData)

        #expect(decoded.schemaVersion == export.schemaVersion)
        #expect(decoded.provider == export.provider)
        #expect(decoded.authMode == export.authMode)
        #expect(decoded.region == export.region)
        #expect(decoded.fieldsPresent == export.fieldsPresent)
        #expect(decoded.servicesCount == export.servicesCount)
        #expect(decoded.billingSummaryPresent == export.billingSummaryPresent)
        #expect(decoded.fetchAttemptsSummary.count == export.fetchAttemptsSummary.count)
    }

    // MARK: - Helpers

    private static func makeEmptySnapshot() -> MiniMaxUsageSnapshot {
        MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: Date())
    }

    private static func makeSuccessOutcome(strategyID: String) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(self.makeSuccessResult(strategyID: strategyID)),
            attempts: [
                ProviderFetchAttempt(
                    strategyID: strategyID,
                    kind: .apiToken,
                    wasAvailable: true,
                    errorDescription: nil),
            ])
    }

    private static func makeSuccessResult(strategyID: String) -> ProviderFetchResult {
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)
        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: strategyID,
            strategyID: strategyID,
            strategyKind: .apiToken)
    }
}
