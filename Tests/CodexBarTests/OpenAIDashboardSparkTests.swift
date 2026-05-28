import Foundation
import Testing
@testable import CodexBarCore

/// Dashboard-path coverage for Codex `additional_rate_limits` (e.g. GPT-5.3-Codex-Spark): the
/// OpenAI web dashboard usage API decodes the same `wham/usage` JSON as the OAuth path, so Spark
/// limits must survive the `dashboardAPIData -> DashboardSnapshotComponents -> OpenAIDashboardSnapshot
/// -> fromAttachedDashboard -> UsageSnapshot.extraRateWindows` chain without disturbing the
/// existing primary/weekly/credits/plan mapping.
struct OpenAIDashboardSparkTests {
    private static func response(from json: String) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }

    @Test
    func `dashboard api data maps additional spark limit into extra windows`() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 43, "reset_at": 1767407914, "limit_window_seconds": 604800 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": {
                "primary_window": { "used_percent": 30, "reset_at": 1766948068, "limit_window_seconds": 18000 }
              }
            }
          ]
        }
        """
        let response = try Self.response(from: json)
        let apiData = OpenAIDashboardFetcher.dashboardAPIData(from: response)
        // Primary/weekly/credits/plan continue to map exactly as before.
        #expect(apiData.primaryLimit?.usedPercent == 22)
        #expect(apiData.secondaryLimit?.usedPercent == 43)
        #expect(apiData.accountPlan == "pro")
        // Spark surfaces with a stable id/title and the additional limit's window percent.
        #expect(apiData.extraRateWindows.count == 1)
        let spark = try #require(apiData.extraRateWindows.first)
        #expect(spark.id == "codex-spark")
        #expect(spark.title == "Codex Spark")
        #expect(spark.window.usedPercent == 30)
        #expect(spark.window.windowMinutes == 300)
        #expect(spark.window.resetsAt != nil)
    }

    @Test
    func `dashboard api data has empty extra windows when additional limits are absent`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 }
          }
        }
        """
        let response = try Self.response(from: json)
        let apiData = OpenAIDashboardFetcher.dashboardAPIData(from: response)
        #expect(apiData.primaryLimit?.usedPercent == 22)
        #expect(apiData.extraRateWindows.isEmpty)
    }

    @Test
    func `dashboard api data tolerates non array additional limits while keeping primary`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 }
          },
          "additional_rate_limits": "unexpected"
        }
        """
        let response = try Self.response(from: json)
        let apiData = OpenAIDashboardFetcher.dashboardAPIData(from: response)
        #expect(apiData.primaryLimit?.usedPercent == 22)
        #expect(apiData.extraRateWindows.isEmpty)
    }

    @Test
    func `dashboard api data keeps valid spark when a malformed sibling is present`() throws {
        // Lossy per-element decode (shared with the OAuth path via CodexUsageResponse) means a single
        // malformed entry cannot discard its valid siblings.
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 }
          },
          "additional_rate_limits": [
            "garbage-not-an-object",
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": {
                "primary_window": { "used_percent": 30, "reset_at": 1766948068, "limit_window_seconds": 18000 }
              }
            },
            42
          ]
        }
        """
        let response = try Self.response(from: json)
        let apiData = OpenAIDashboardFetcher.dashboardAPIData(from: response)
        #expect(apiData.primaryLimit?.usedPercent == 22)
        #expect(apiData.extraRateWindows.count == 1)
        #expect(apiData.extraRateWindows.first?.id == "codex-spark")
        #expect(apiData.extraRateWindows.first?.window.usedPercent == 30)
    }

    @Test
    func `dashboard snapshot exposes extra rate windows via to usage snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_766_948_000)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondaryLimit: RateWindow(
                usedPercent: 43,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "codex-spark",
                    title: "Codex Spark",
                    window: RateWindow(
                        usedPercent: 30,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(60 * 60),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let usage = try #require(snapshot.toUsageSnapshot(provider: .codex))
        // Primary/weekly behavior preserved.
        #expect(usage.primary?.usedPercent == 22)
        #expect(usage.secondary?.usedPercent == 43)
        // Spark surfaces through UsageSnapshot.extraRateWindows for dashboard-source users.
        let extras = try #require(usage.extraRateWindows)
        #expect(extras.map(\.id) == ["codex-spark"])
        #expect(extras.first?.window.usedPercent == 30)
    }

    @Test
    func `dashboard snapshot codable round trips extra rate windows`() throws {
        let now = Date(timeIntervalSince1970: 1_766_948_000)
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "codex-spark",
                    title: "Codex Spark",
                    window: RateWindow(
                        usedPercent: 30,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(60 * 60),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(OpenAIDashboardSnapshot.self, from: data)
        #expect(decoded.extraRateWindows?.map(\.id) == ["codex-spark"])
        #expect(decoded.extraRateWindows?.first?.window.usedPercent == 30)
    }

    @Test
    func `dashboard snapshot decoder preserves absence of extra rate windows`() throws {
        // Older cached snapshots predate the field; decoding such payloads must yield nil and never
        // throw, so existing dashboard caches keep working.
        let json = """
        {
          "signedInEmail": "codex@example.com",
          "codeReviewRemainingPercent": null,
          "creditEvents": [],
          "dailyBreakdown": [],
          "usageBreakdown": [],
          "creditsPurchaseURL": null,
          "updatedAt": "2026-04-30T19:27:07Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(OpenAIDashboardSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.extraRateWindows == nil)
    }
}
