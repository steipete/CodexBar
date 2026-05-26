import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekUsageCostParserTests {
    // Fixtures use date 2026-05-26
    private let fixtureNow = Date(timeIntervalSince1970: 1_779_796_800) // 2026-05-26 12:00:00 UTC
    private let fixtureCalendar: Calendar = {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    // MARK: - Amount Parser Tests

    @Test
    func `amount parser decodes total and days`() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                    {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1305432"},
                    {"type": "RESPONSE_TOKEN", "amount": "656338"},
                    {"type": "REQUEST", "amount": "1212"}
                  ]
                }
              ],
              "days": [
                {
                  "date": "2026-05-26",
                  "data": [
                    {
                      "model": "deepseek-v4-flash",
                      "usage": [
                        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                        {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1305432"},
                        {"type": "RESPONSE_TOKEN", "amount": "656338"},
                        {"type": "REQUEST", "amount": "1212"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let payload = try DeepSeekUsageCostParser.decodeAmountPayload(data: Data(json.utf8))
        #expect(payload.code == 0)
        #expect(payload.data?.bizCode == 0)
        #expect(payload.data?.bizData?.total?.count == 1)
        #expect(payload.data?.bizData?.total?[0].model == "deepseek-v4-flash")
        #expect(payload.data?.bizData?.days?.count == 1)
        #expect(payload.data?.bizData?.days?[0].date == "2026-05-26")
    }

    @Test
    func `amount parser handles missing biz_data gracefully`() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": null
        }
        """
        let payload = try DeepSeekUsageCostParser.decodeAmountPayload(data: Data(json.utf8))
        #expect(payload.code == 0)
        #expect(payload.data?.bizData?.total == nil)
        #expect(payload.data?.bizData?.days == nil)
    }

    // MARK: - Cost Parser Tests

    @Test
    func `cost parser decodes total, days, and currency`() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                      {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1.3054320000000000"},
                      {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"},
                      {"type": "REQUEST", "amount": "0"}
                    ]
                  }
                ],
                "days": [
                  {
                    "date": "2026-05-26",
                    "data": [
                      {
                        "model": "deepseek-v4-flash",
                        "usage": [
                          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1.3054320000000000"},
                          {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"},
                          {"type": "REQUEST", "amount": "0"}
                        ]
                      }
                    ]
                  }
                ],
                "currency": "CNY"
              }
            ]
          }
        }
        """
        let payload = try DeepSeekUsageCostParser.decodeCostPayload(data: Data(json.utf8))
        #expect(payload.code == 0)
        #expect(payload.data?.bizCode == 0)
        #expect(payload.data?.bizData?[0].currency == "CNY")
        #expect(payload.data?.bizData?[0].total?.count == 1)
        #expect(payload.data?.bizData?[0].days?.count == 1)
        #expect(payload.data?.bizData?[0].days?[0].date == "2026-05-26")
    }

    @Test
    func `cost parser handles empty biz_data`() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": []
          }
        }
        """
        let payload = try DeepSeekUsageCostParser.decodeCostPayload(data: Data(json.utf8))
        #expect(payload.code == 0)
        #expect(payload.data?.bizData?.isEmpty == true)
    }

    // MARK: - String Parsing Tests

    @Test
    func `string token parsing works`() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                    {"type": "RESPONSE_TOKEN", "amount": "656338"}
                  ]
                }
              ],
              "days": []
            }
          }
        }
        """
        let payload = try DeepSeekUsageCostParser.decodeAmountPayload(data: Data(json.utf8))
        #expect(payload.data?.bizData?.total?[0].usage?[0].type == "PROMPT_CACHE_HIT_TOKEN")
        #expect(payload.data?.bizData?.total?[0].usage?[0].amount == "100686720")
    }

    @Test
    func `decimal cost parsing works`() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"}
                    ]
                  }
                ],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """
        let payload = try DeepSeekUsageCostParser.decodeCostPayload(data: Data(json.utf8))
        #expect(payload.data?.bizData?[0].total?[0].usage?[0].amount == "2.0137344000000000")
    }

    // MARK: - Aggregation Tests

    @Test
    func `aggregation computes today token totals`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                    {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1305432"},
                    {"type": "RESPONSE_TOKEN", "amount": "656338"},
                    {"type": "REQUEST", "amount": "1212"}
                  ]
                }
              ],
              "days": [
                {
                  "date": "2026-05-26",
                  "data": [
                    {
                      "model": "deepseek-v4-flash",
                      "usage": [
                        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                        {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1305432"},
                        {"type": "RESPONSE_TOKEN", "amount": "656338"},
                        {"type": "REQUEST", "amount": "1212"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                      {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1.3054320000000000"},
                      {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"},
                      {"type": "REQUEST", "amount": "0"}
                    ]
                  }
                ],
                "days": [
                  {
                    "date": "2026-05-26",
                    "data": [
                      {
                        "model": "deepseek-v4-flash",
                        "usage": [
                          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1.3054320000000000"},
                          {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"},
                          {"type": "REQUEST", "amount": "0"}
                        ]
                      }
                    ]
                  }
                ],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)

        // Today is 2026-05-26 per the test data
        #expect(summary.todayTokens == 102_648_490) // 100_686_720 + 1_305_432 + 656_338
        #expect(summary.requestCount == 1212)
        #expect(summary.currency == "CNY")
    }

    @Test
    func `aggregation uses injected now and calendar for today bucket`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
                    {"type": "REQUEST", "amount": "1"}
                  ]
                }
              ],
              "days": [
                {
                  "date": "2026-05-26",
                  "data": [
                    {
                      "model": "deepseek-v4-flash",
                      "usage": [
                        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
                        {"type": "REQUEST", "amount": "1"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        var nextMonthUTC = Calendar(identifier: .gregorian)
        nextMonthUTC.timeZone = TimeZone(identifier: "UTC") ?? .current
        let injectedNow = try #require(nextMonthUTC.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)))

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: injectedNow,
            calendar: nextMonthUTC)

        #expect(summary.todayTokens == 0)
        #expect(summary.currentMonthTokens == 0)
    }

    @Test
    func `aggregation computes today cost totals`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                    {"type": "RESPONSE_TOKEN", "amount": "656338"}
                  ]
                }
              ],
              "days": [
                {
                  "date": "2026-05-26",
                  "data": [
                    {
                      "model": "deepseek-v4-flash",
                      "usage": [
                        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                        {"type": "RESPONSE_TOKEN", "amount": "656338"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                      {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"}
                    ]
                  }
                ],
                "days": [
                  {
                    "date": "2026-05-26",
                    "data": [
                      {
                        "model": "deepseek-v4-flash",
                        "usage": [
                          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                          {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"}
                        ]
                      }
                    ]
                  }
                ],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)

        #expect(abs((summary.todayCost ?? 0) - 3.3264104) < 0.0001)
        #expect(summary.currentMonthCost != nil)
    }

    @Test
    func `aggregation computes model and category breakdown`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100686720"},
                    {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1305432"},
                    {"type": "RESPONSE_TOKEN", "amount": "656338"}
                  ]
                }
              ],
              "days": []
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0137344000000000"},
                      {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "1.3054320000000000"},
                      {"type": "RESPONSE_TOKEN", "amount": "1.3126760000000000"}
                    ]
                  }
                ],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)

        #expect(summary.topModel == "deepseek-v4-flash")
        #expect(summary.categoryBreakdown.count == 3)

        let cacheHit = summary.categoryBreakdown.first { $0.category == DeepSeekUsageCategory.promptCacheHitToken }
        #expect(cacheHit?.tokens == 100_686_720)
        #expect(abs((cacheHit?.cost ?? 0) - 2.0137344) < 0.0001)

        let cacheMiss = summary.categoryBreakdown.first { $0.category == DeepSeekUsageCategory.promptCacheMissToken }
        #expect(cacheMiss?.tokens == 1_305_432)
        #expect(abs((cacheMiss?.cost ?? 0) - 1.305432) < 0.0001)

        let response = summary.categoryBreakdown.first { $0.category == DeepSeekUsageCategory.responseToken }
        #expect(response?.tokens == 656_338)
        #expect(abs((response?.cost ?? 0) - 1.312676) < 0.0001)
    }

    // MARK: - Unknown Types Handling

    @Test
    func `unknown usage types are ignored safely`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
                    {"type": "UNKNOWN_TYPE", "amount": "999"},
                    {"type": "RESPONSE_TOKEN", "amount": "200"}
                  ]
                }
              ],
              "days": []
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "1.0"},
                      {"type": "UNKNOWN_TYPE", "amount": "99.0"},
                      {"type": "RESPONSE_TOKEN", "amount": "2.0"}
                    ]
                  }
                ],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)

        // Unknown type should be ignored - only known categories with non-zero tokens appear in breakdown
        // todayTokens comes from daily data which is empty in this test, so it's 0
        #expect(summary.todayTokens == 0)
        #expect(summary.categoryBreakdown.count == 3) // Always 3 categories, even if some have 0 tokens
    }

    // MARK: - Error Handling

    @Test
    func `missing fields fails closed`() {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": null
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(costJSON.utf8),
                now: fixtureNow,
                calendar: fixtureCalendar)
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `non-zero biz_code fails closed`() {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 1001,
            "biz_msg": "some error",
            "biz_data": {
              "total": [],
              "days": []
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(costJSON.utf8))
        } throws: { error in
            guard case DeepSeekUsageError.apiError = error else { return false }
            return true
        }
    }

    @Test
    func `invalid JSON fails closed`() {
        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data("not json".utf8),
                costData: Data("{}".utf8))
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    // MARK: - Edge Cases

    @Test
    func `empty days array works`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [],
              "days": []
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)

        #expect(summary.todayTokens == 0)
        #expect(summary.currentMonthTokens == 0)
        #expect(summary.todayCost == nil)
        #expect(summary.currentMonthCost == nil)
        #expect(summary.daily.isEmpty)
    }

    @Test
    func `multiple models works`() throws {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": [
                {
                  "model": "deepseek-v4-flash",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
                    {"type": "RESPONSE_TOKEN", "amount": "50"}
                  ]
                },
                {
                  "model": "deepseek-chat",
                  "usage": [
                    {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "200"},
                    {"type": "RESPONSE_TOKEN", "amount": "100"}
                  ]
                }
              ],
              "days": [
                {
                  "date": "2026-05-26",
                  "data": [
                    {
                      "model": "deepseek-v4-flash",
                      "usage": [
                        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "100"},
                        {"type": "RESPONSE_TOKEN", "amount": "50"}
                      ]
                    },
                    {
                      "model": "deepseek-chat",
                      "usage": [
                        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "200"},
                        {"type": "RESPONSE_TOKEN", "amount": "100"}
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let costJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": [
              {
                "total": [
                  {
                    "model": "deepseek-v4-flash",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "1.0"},
                      {"type": "RESPONSE_TOKEN", "amount": "0.5"}
                    ]
                  },
                  {
                    "model": "deepseek-chat",
                    "usage": [
                      {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "2.0"},
                      {"type": "RESPONSE_TOKEN", "amount": "1.0"}
                    ]
                  }
                ],
                "days": [],
                "currency": "CNY"
              }
            ]
          }
        }
        """

        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)

        #expect(summary.topModel == "deepseek-chat") // 300 tokens vs 150 tokens
        #expect(summary.todayTokens == 450) // 150 + 300
    }
}
