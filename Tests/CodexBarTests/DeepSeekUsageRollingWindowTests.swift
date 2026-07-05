import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekUsageRollingWindowTests {
    @Test
    func `merges prior month daily rows for rolling 30 day window`() throws {
        let calendar: Calendar = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return cal
        }()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12)))

        let priorAmountJSON = Self.amountJSON(
            days: [
                ("2026-05-30", "deepseek-chat", 100),
                ("2026-05-31", "deepseek-chat", 200),
            ])
        let currentAmountJSON = Self.amountJSON(
            days: [
                ("2026-06-01", "deepseek-chat", 50),
                ("2026-06-02", "deepseek-chat", 60),
                ("2026-06-03", "deepseek-chat", 70),
            ])
        let priorCostJSON = Self.costJSON(
            days: [
                ("2026-05-30", "deepseek-chat", 1.0),
                ("2026-05-31", "deepseek-chat", 2.0),
            ])
        let currentCostJSON = Self.costJSON(
            days: [
                ("2026-06-01", "deepseek-chat", 0.5),
                ("2026-06-02", "deepseek-chat", 0.6),
                ("2026-06-03", "deepseek-chat", 0.7),
            ])

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(currentAmountJSON.utf8),
            costData: Data(currentCostJSON.utf8),
            priorAmountData: Data(priorAmountJSON.utf8),
            priorCostData: Data(priorCostJSON.utf8),
            now: now,
            calendar: calendar)

        #expect(summary.daily.map(\.date) == [
            "2026-05-30",
            "2026-05-31",
            "2026-06-01",
            "2026-06-02",
            "2026-06-03",
        ])
        #expect(summary.currentMonthTokens == 180) // June only
        #expect(summary.todayTokens == 70)
        #expect(summary.last30DaysTokens == 480)
    }

    private static func amountJSON(days: [(String, String, Int)]) -> String {
        let dayEntries = days.map { date, model, tokens in
            """
                    {
                      "date": "\(date)",
                      "data": [
                        {
                          "model": "\(model)",
                          "usage": [
                            {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "\(tokens)"}
                          ]
                        }
                      ]
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [],
              "days": [
        \(dayEntries)
              ]
            }
          }
        }
        """
    }

    private static func costJSON(days: [(String, String, Double)]) -> String {
        let dayEntries = days.map { date, model, cost in
            """
                    {
                      "date": "\(date)",
                      "data": [
                        {
                          "model": "\(model)",
                          "usage": [
                            {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "\(cost)"}
                          ]
                        }
                      ]
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [],
                "days": [
        \(dayEntries)
                ],
                "currency": "USD"
              }
            ]
          }
        }
        """
    }
}
