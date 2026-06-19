import Foundation
import Testing
@testable import CodexBarCore

struct CodexAdditionalRateLimitsTests {
    @Test
    func `maps additional spark limit into a named extra rate window`() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 30,
                  "reset_at": 1766948068,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 12345
                },
                "secondary_window": {
                  "used_percent": 100,
                  "reset_at": 1767407914,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 56789
                }
              }
            }
          ]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
        // Primary/weekly behavior is unchanged.
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.secondary?.usedPercent == 43)
        // Spark surfaces as distinct 5-hour and weekly extra windows.
        let extras = try #require(snapshot.extraRateWindows)
        #expect(extras.count == 2)
        let spark = try #require(extras.first)
        #expect(spark.id == "codex-spark")
        #expect(spark.title == "Codex Spark 5-hour")
        #expect(spark.window.usedPercent == 30)
        #expect(spark.window.windowMinutes == 300)
        #expect(spark.window.resetsAt != nil)
        let weekly = try #require(extras.last)
        #expect(weekly.id == "codex-spark-weekly")
        #expect(weekly.title == "Codex Spark Weekly")
        #expect(weekly.window.usedPercent == 100)
        #expect(weekly.window.windowMinutes == 10080)
        #expect(weekly.window.resetsAt != nil)
    }

    @Test
    func `keeps valid spark window when an additional limit sibling is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 43, "reset_at": 1767407914, "limit_window_seconds": 604800 }
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
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
        // Valid primary/weekly fields do not regress.
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.secondary?.usedPercent == 43)
        // The malformed siblings are skipped, but the valid Spark entry survives.
        let extras = try #require(snapshot.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.id == "codex-spark")
        #expect(extras.first?.window.usedPercent == 30)
    }

    @Test
    func `keeps primary usage when every additional limit element is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 }
          },
          "additional_rate_limits": ["garbage", 1, true]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `omits extra rate windows when additional limits are absent`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `tolerates malformed additional limits while keeping primary window`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": "unexpected"
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `skips additional limits without a usable window`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": null
            }
          ]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `maps non spark additional limit using a slugged id and api label`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "GPT-5.3-Codex-Mini",
            "metered_feature": "gpt_5_3_codex_mini",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 12,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          },
          {
            "limit_name": "GPT-5.3-Codex-Mini",
            "metered_feature": "gpt_5_3_codex_mini",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 99,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)
        // Duplicate ids collapse to the first occurrence.
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.id == "codex-gpt-5-3-codex-mini")
        #expect(window.title == "GPT-5.3-Codex-Mini")
        #expect(window.window.usedPercent == 12)
    }

    @Test
    func `dedupes split spark entries by window kind`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 20,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          },
          {
            "limit_name": "GPT-5.3-Codex-Spark Weekly",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 80,
                "reset_at": 1767407914,
                "limit_window_seconds": 604800
              }
            }
          },
          {
            "limit_name": "GPT-5.3-Codex-Spark Duplicate",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 99,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        #expect(windows.map(\.id) == ["codex-spark", "codex-spark-weekly"])
        #expect(windows.first?.window.usedPercent == 20)
        #expect(windows.last?.window.usedPercent == 80)
    }
}
