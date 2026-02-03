import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageDecodingTests {
    @Test
    func decodesDailyReportTypeFormat() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "2025-12-20",
              "inputTokens": 10,
              "cacheReadTokens": 2,
              "cacheCreationTokens": 3,
              "outputTokens": 20,
              "totalTokens": 30,
              "costUSD": 0.12
            }
          ],
          "summary": {
            "totalInputTokens": 10,
            "totalOutputTokens": 20,
            "cacheReadTokens": 2,
            "cacheCreationTokens": 3,
            "totalTokens": 30,
            "totalCostUSD": 0.12
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].date == "2025-12-20")
        #expect(report.data[0].totalTokens == 30)
        #expect(report.data[0].cacheReadTokens == 2)
        #expect(report.data[0].cacheCreationTokens == 3)
        #expect(report.data[0].costUSD == 0.12)
        #expect(report.summary?.totalCostUSD == 0.12)
        #expect(report.summary?.cacheReadTokens == 2)
        #expect(report.summary?.cacheCreationTokens == 3)
    }

    @Test
    func decodesDailyReportLegacyFormat() throws {
        let json = """
        {
          "daily": [
            {
              "date": "2025-12-20",
              "inputTokens": 1,
              "cacheReadTokens": 2,
              "cacheCreationTokens": 3,
              "outputTokens": 2,
              "totalTokens": 3,
              "totalCost": 0.01
            }
          ],
          "totals": {
            "totalInputTokens": 1,
            "totalOutputTokens": 2,
            "cacheReadTokens": 2,
            "cacheCreationTokens": 3,
            "totalTokens": 3,
            "totalCost": 0.01
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.summary?.totalTokens == 3)
        #expect(report.summary?.totalCostUSD == 0.01)
        #expect(report.data[0].cacheReadTokens == 2)
        #expect(report.data[0].cacheCreationTokens == 3)
        #expect(report.summary?.cacheReadTokens == 2)
        #expect(report.summary?.cacheCreationTokens == 3)
    }

    @Test
    func decodesLegacyCacheTokenKeys() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "2025-12-20",
              "cacheReadInputTokens": 4,
              "cacheCreationInputTokens": 5,
              "totalTokens": 9
            }
          ],
          "summary": {
            "totalCacheReadTokens": 4,
            "totalCacheCreationTokens": 5,
            "totalTokens": 9
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].cacheReadTokens == 4)
        #expect(report.data[0].cacheCreationTokens == 5)
        #expect(report.summary?.cacheReadTokens == 4)
        #expect(report.summary?.cacheCreationTokens == 5)
    }

    @Test
    func decodesDailyReportLegacyFormatWithModelMap() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "inputTokens": 10,
              "outputTokens": 20,
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": {
                "gpt-5.2": {
                  "inputTokens": 10,
                  "outputTokens": 20,
                  "totalTokens": 30,
                  "isFallback": false
                }
              }
            }
          ],
          "totals": {
            "totalTokens": 30,
            "costUSD": 0.12
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].costUSD == 0.12)
        #expect(report.data[0].modelsUsed == ["gpt-5.2"])
    }

    @Test
    func decodesDailyReportLegacyFormatWithModelMapSorted() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": {
                "z-model": { "totalTokens": 10 },
                "a-model": { "totalTokens": 20 },
                "m-model": { "totalTokens": 0 }
              }
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == ["a-model", "m-model", "z-model"])
    }

    @Test
    func decodesDailyReportLegacyFormatWithEmptyModelMapAsNil() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": {}
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == nil)
    }

    @Test
    func decodesDailyReportLegacyFormatPrefersModelsUsedListOverModelsMap() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "modelsUsed": ["gpt-5.2"],
              "models": {
                "ignored-model": { "totalTokens": 30 }
              }
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == ["gpt-5.2"])
    }

    @Test
    func decodesDailyReportLegacyFormatWithModelsList() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": ["gpt-5.2", "gpt-5.2-mini"]
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == ["gpt-5.2", "gpt-5.2-mini"])
    }

    @Test
    func decodesDailyReportLegacyFormatWithInvalidModelsField() throws {
        let json = """
        {
          "daily": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 0.12,
              "models": "gpt-5.2"
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data[0].modelsUsed == nil)
    }

    @Test
    func decodesMonthlyReportLegacyFormat() throws {
        let json = """
        {
          "monthly": [
            {
              "month": "Dec 2025",
              "totalTokens": 123,
              "costUSD": 4.56
            }
          ],
          "totals": {
            "totalTokens": 123,
            "costUSD": 4.56
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageMonthlyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].month == "Dec 2025")
        #expect(report.data[0].costUSD == 4.56)
        #expect(report.summary?.totalCostUSD == 4.56)
    }

    @Test
    func selectsMostRecentSession() throws {
        let json = """
        {
          "type": "session",
          "data": [
            {
              "session": "A",
              "totalTokens": 100,
              "costUSD": 0.50,
              "lastActivity": "2025-12-19"
            },
            {
              "session": "B",
              "totalTokens": 50,
              "costUSD": 0.20,
              "lastActivity": "2025-12-20T12:00:00Z"
            },
            {
              "session": "C",
              "totalTokens": 200,
              "costUSD": 0.10,
              "lastActivity": "2025-12-20T11:00:00Z"
            }
          ],
          "summary": {
            "totalCostUSD": 0.80
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageSessionReport.self, from: Data(json.utf8))
        let selected = CostUsageFetcher.selectCurrentSession(from: report.data)
        #expect(selected?.session == "B")
    }

    @Test
    func tokenSnapshotSelectsMostRecentDay() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "Dec 20, 2025",
              "totalTokens": 30,
              "costUSD": 1.23
            },
            {
              "date": "2025-12-21",
              "totalTokens": 10,
              "costUSD": 4.56
            }
          ],
          "summary": {
            "totalCostUSD": 5.79
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_766_275_200) // 2025-12-21
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: now)
        #expect(snapshot.sessionTokens == 10)
        #expect(snapshot.sessionCostUSD == 4.56)
        #expect(snapshot.last30DaysCostUSD == 5.79)
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func tokenSnapshotUsesSummaryTotalCostWhenAvailable() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            { "date": "2025-12-20", "costUSD": 1.00 },
            { "date": "2025-12-21", "costUSD": 2.00 }
          ],
          "summary": {
            "totalCostUSD": 99.00
          }
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: Date())
        #expect(snapshot.last30DaysCostUSD == 99.00)
    }

    @Test
    func tokenSnapshotFallsBackToSummedEntriesWhenSummaryMissing() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            { "date": "2025-12-20", "costUSD": 1.00 },
            { "date": "2025-12-21", "costUSD": 2.00 }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: Date())
        #expect(snapshot.last30DaysCostUSD == 3.00)
    }

    @Test
    func tokenSnapshotReturnsNilTotalWhenNoCostsPresent() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            { "date": "2025-12-20", "totalTokens": 10 },
            { "date": "2025-12-21", "totalTokens": 20 }
          ]
        }
        """

        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: Date())
        #expect(snapshot.last30DaysCostUSD == nil)
    }
}
