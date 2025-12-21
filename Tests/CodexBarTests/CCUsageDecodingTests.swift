import Foundation
import Testing

@testable import CodexBarCore

@Suite
struct CCUsageDecodingTests {
    @Test
    func decodesDailyReportTypeFormat() throws {
        let json = """
        {
          "type": "daily",
          "data": [
            {
              "date": "2025-12-20",
              "inputTokens": 10,
              "outputTokens": 20,
              "totalTokens": 30,
              "costUSD": 0.12
            }
          ],
          "summary": {
            "totalInputTokens": 10,
            "totalOutputTokens": 20,
            "totalTokens": 30,
            "totalCostUSD": 0.12
          }
        }
        """

        let report = try JSONDecoder().decode(CCUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].date == "2025-12-20")
        #expect(report.data[0].totalTokens == 30)
        #expect(report.data[0].costUSD == 0.12)
        #expect(report.summary?.totalCostUSD == 0.12)
    }

    @Test
    func decodesDailyReportLegacyFormat() throws {
        let json = """
        {
          "daily": [
            {
              "date": "2025-12-20",
              "inputTokens": 1,
              "outputTokens": 2,
              "totalTokens": 3,
              "totalCost": 0.01
            }
          ],
          "totals": {
            "totalInputTokens": 1,
            "totalOutputTokens": 2,
            "totalTokens": 3,
            "totalCost": 0.01
          }
        }
        """

        let report = try JSONDecoder().decode(CCUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.summary?.totalTokens == 3)
        #expect(report.summary?.totalCostUSD == 0.01)
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

        let report = try JSONDecoder().decode(CCUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.count == 1)
        #expect(report.data[0].costUSD == 0.12)
        #expect(report.data[0].modelsUsed == ["gpt-5.2"])
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

        let report = try JSONDecoder().decode(CCUsageMonthlyReport.self, from: Data(json.utf8))
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

        let report = try JSONDecoder().decode(CCUsageSessionReport.self, from: Data(json.utf8))
        let selected = CCUsageFetcher.selectCurrentSession(from: report.data)
        #expect(selected?.session == "B")
    }
}
