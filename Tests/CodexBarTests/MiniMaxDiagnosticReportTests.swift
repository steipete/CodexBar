import CodexBarCore
import Foundation
import Testing

struct MiniMaxDiagnosticReportTests {
    @Test
    func `report has correct structure`() {
        let authSources = MiniMaxDiagnosticReport.AuthSourcesPresent(
            apiTokenEnv: true,
            codingPlanTokenEnv: false,
            cookieHeaderEnv: true)

        let report = MiniMaxDiagnosticReport(
            authSourcesPresent: authSources,
            endpointsAttempted: ["minimax.api", "minimax.web"],
            suspectedPlanFields: ["planName", "availablePrompts"],
            suspectedDateFields: ["resetsAt"],
            suspectedSubscriptionFields: [])

        #expect(report.provider == "minimax")
        #expect(report.schemaVersion == "1.0")
        #expect(report.liveFetch == "notPerformed")
        #expect(report.authSourcesPresent.apiTokenEnv == true)
        #expect(report.authSourcesPresent.codingPlanTokenEnv == false)
        #expect(report.authSourcesPresent.cookieHeaderEnv == true)
        #expect(report.endpointsAttempted.count == 2)
        #expect(report.suspectedPlanFields.contains("planName"))
        #expect(report.suspectedDateFields.contains("resetsAt"))
        #expect(report.suspectedSubscriptionFields.isEmpty)
    }

    @Test
    func `redaction summary has correct values`() {
        let redaction = MiniMaxDiagnosticReport.RedactionSummary()

        #expect(redaction.cookies == "removed")
        #expect(redaction.tokens == "removed")
        #expect(redaction.ids == "redacted")
        #expect(redaction.emails == "redacted")
    }

    @Test
    func `report serializes to JSON`() {
        let authSources = MiniMaxDiagnosticReport.AuthSourcesPresent(
            apiTokenEnv: false,
            codingPlanTokenEnv: false,
            cookieHeaderEnv: false)

        let report = MiniMaxDiagnosticReport(
            authSourcesPresent: authSources,
            endpointsAttempted: ["minimax.api"],
            suspectedPlanFields: ["planName"],
            suspectedDateFields: ["resetsAt", "updatedAt"],
            suspectedSubscriptionFields: [])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try? encoder.encode(report)
        #expect(data != nil)

        let json = data.flatMap { String(data: $0, encoding: .utf8) }
        #expect(json != nil)
        #expect(json?.contains("\"provider\"") ?? false)
        #expect(json?.contains("\"schemaVersion\"") ?? false)
        #expect(json?.contains("\"liveFetch\"") ?? false)
        #expect(json?.contains("\"authSourcesPresent\"") ?? false)
        #expect(json?.contains("\"endpointsAttempted\"") ?? false)
        #expect(json?.contains("\"suspectedPlanFields\"") ?? false)
        #expect(json?.contains("\"redaction\"") ?? false)
        #expect(json?.contains("\"minimax\"") ?? false)
    }

    @Test
    func `no live fetch means response shape is explicit null`() {
        let authSources = MiniMaxDiagnosticReport.AuthSourcesPresent(
            apiTokenEnv: false,
            codingPlanTokenEnv: false,
            cookieHeaderEnv: false)

        let report = MiniMaxDiagnosticReport(
            authSourcesPresent: authSources,
            endpointsAttempted: ["minimax.api"],
            responseShape: nil,
            suspectedPlanFields: ["planName"],
            suspectedDateFields: ["resetsAt"],
            suspectedSubscriptionFields: [])

        #expect(report.responseShape == nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try? encoder.encode(report)
        let json = data.flatMap { String(data: $0, encoding: .utf8) }

        #expect(json != nil)
        #expect(json?.contains("\"responseShape\"") ?? false)
        #expect(json?.contains("null") ?? false)
        #expect(report.suspectedSubscriptionFields.isEmpty)
    }

    @Test
    func `generatedAt serializes as ISO8601 string`() {
        let authSources = MiniMaxDiagnosticReport.AuthSourcesPresent(
            apiTokenEnv: false,
            codingPlanTokenEnv: false,
            cookieHeaderEnv: false)

        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let report = MiniMaxDiagnosticReport(
            generatedAt: fixedDate,
            authSourcesPresent: authSources,
            endpointsAttempted: ["minimax.api"],
            suspectedPlanFields: [],
            suspectedDateFields: [],
            suspectedSubscriptionFields: [])

        let encoder = JSONEncoder()
        let data = try? encoder.encode(report)
        let json = data.flatMap { String(data: $0, encoding: .utf8) }

        #expect(json != nil)
        #expect(json?.contains("2023-11-14") ?? false)
        #expect(json?.contains("T") ?? false)
        #expect(json?.contains(":") ?? false)
    }

    @Test
    func `auth sources detection is boolean only`() {
        let withValues = MiniMaxDiagnosticReport.detectAuthSources(from: [
            "MINIMAX_API_KEY": "sk-test",
            "MINIMAX_CODING_API_KEY": "",
            "MINIMAX_COOKIE": "   "
        ])

        #expect(withValues.apiTokenEnv == true)
        #expect(withValues.codingPlanTokenEnv == false)
        #expect(withValues.cookieHeaderEnv == false)
    }

    @Test
    func `auth sources detection returns false for empty or quoted-empty values`() {
        let withEmpty = MiniMaxDiagnosticReport.detectAuthSources(from: [
            "MINIMAX_API_KEY": "",
            "MINIMAX_CODING_API_KEY": "\"\""
        ])

        #expect(withEmpty.apiTokenEnv == false)
        #expect(withEmpty.codingPlanTokenEnv == false)
    }

    @Test
    func `safe endpoints returns expected labels`() {
        let endpoints = MiniMaxDiagnosticReport.safeEndpoints
        #expect(endpoints == ["minimax.api", "minimax.web"])
    }

    @Test
    func `suspected fields returns correct field names`() {
        let fields = MiniMaxDiagnosticReport.suspectedFields
        #expect(fields.plan == ["planName", "availablePrompts", "currentPrompts", "remainingPrompts", "windowMinutes", "usedPercent"])
        #expect(fields.date == ["resetsAt", "updatedAt"])
        #expect(fields.subscription.isEmpty)
    }

    @Test
    func `no sensitive values leak into JSON output`() {
        let authSources = MiniMaxDiagnosticReport.AuthSourcesPresent(
            apiTokenEnv: true,
            codingPlanTokenEnv: true,
            cookieHeaderEnv: true)

        let report = MiniMaxDiagnosticReport(
            authSourcesPresent: authSources,
            endpointsAttempted: ["minimax.api", "minimax.web"],
            suspectedPlanFields: ["planName"],
            suspectedDateFields: ["resetsAt"],
            suspectedSubscriptionFields: [])

        let encoder = JSONEncoder()
        let data = try? encoder.encode(report)
        let json = data.flatMap { String(data: $0, encoding: .utf8) }

        #expect(!(json?.contains("sk-test-secret") ?? false))
        #expect(!(json?.contains("Bearer") ?? false))
        #expect(!(json?.contains("user@example.com") ?? false))
        #expect(!(json?.contains("12345678") ?? false))
        #expect(!(json?.contains("MINIMAX_API_KEY") ?? false))
        #expect(!(json?.contains("sk-") ?? false))
    }

    @Test
    func `safe secrets do not appear in JSON even when auth sources are true`() {
        let authSources = MiniMaxDiagnosticReport.AuthSourcesPresent(
            apiTokenEnv: true,
            codingPlanTokenEnv: true,
            cookieHeaderEnv: true)

        let report = MiniMaxDiagnosticReport(
            authSourcesPresent: authSources,
            endpointsAttempted: ["minimax.api", "minimax.web"],
            suspectedPlanFields: ["planName"],
            suspectedDateFields: ["resetsAt"],
            suspectedSubscriptionFields: [])

        let encoder = JSONEncoder()
        let data = try? encoder.encode(report)
        let json = data.flatMap { String(data: $0, encoding: .utf8) }

        #expect(!(json?.contains("sk-") ?? false))
        #expect(!(json?.contains("Bearer") ?? false))
        #expect(!(json?.contains("@") ?? false))
        #expect(!(json?.contains("12345678") ?? false))
        #expect(!(json?.contains("MINIMAX_") ?? false))
        #expect(!(json?.contains("secret") ?? false))
    }
}