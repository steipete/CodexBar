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

extension DeepSeekUsageCostParserTests {
    @Test(arguments: [true, false])
    func `by-api-key series fold into daily totals`(stringKey: Bool) throws {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let amountJSON = """
        {
          "code": 0,
          "data": {
            "biz_data": {
              "series": [{
                "api_key": \(stringKey ? "\"key-1\"" : "{\"name\":\"main\",\"tracking_id\":\"key-1\"}"),
                "model": "deepseek-chat",
                "buckets": [{
                  "time": \(day),
                  "usage": {
                    "PROMPT_CACHE_HIT_TOKEN": "100",
                    "PROMPT_CACHE_MISS_TOKEN": 50,
                    "RESPONSE_TOKEN": 25,
                    "REQUEST": 8675,
                    "FUNCTION_CALL": 13
                  }
                }]
              }],
              "function_series": [{
                "model": "server-tool-search",
                "buckets": [
                  {"time": \(day - 86400), "usage": {"FUNCTION_CALL": 2}},
                  {"time": \(day), "usage": {"FUNCTION_CALL": "3", "REQUEST": 3}},
                  {"time": \(day - 30 * 86400), "usage": {"FUNCTION_CALL": 20}}
                ]
              }]
            }
          }
        }
        """
        let costJSON = """
        {
          "code": 0,
          "data": {
            "biz_data": {
              "data": [{
                "currency": "CNY",
                "series": [{
                  "api_key": \(stringKey ? "\"key-1\"" : "{\"name\":\"main\",\"tracking_id\":\"key-1\"}"),
                  "model": "deepseek-chat",
                  "buckets": [{"time": \(day), "cost": "0.12"}]
                }]
              }]
            }
          }
        }
        """
        let summary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(summary.todayTokens == 175)
        #expect(summary.todayCost == 0.12)
        #expect(summary.requestCount == 8678)
        #expect(summary.currentMonthRequestCount == 8680)
        #expect(summary.currentMonthTokens == 175)
        #expect(summary.currentMonthCost == 0.12)
        #expect(summary.apiKeyCount == 1)
        #expect(summary.topModel == "deepseek-chat")
        #expect(summary.daily.count == 2)
        #expect(summary.daily.first?.requestCount == 2)
        #expect(summary.daily.last?.totalTokens == 175)
        #expect(summary.daily.last?.requestCount == 8678)
        #expect(summary.daily.last?.cost == 0.12)
        #expect(summary.period == .last30Days)
    }

    @Test
    func `by-api-key nested error code is rejected`() {
        let json = """
        {"code": 0, "data": {"biz_code": 40002, "biz_data": null}}
        """
        #expect(throws: DeepSeekUsageError.self) {
            try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: Data(json.utf8),
                costData: Data(json.utf8),
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        }
    }

    @Test
    func `by-api-key missing biz_data is rejected`() {
        let json = """
        {"code": 0, "data": {"biz_code": 0}}
        """
        #expect(throws: DeepSeekUsageError.self) {
            try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: Data(json.utf8),
                costData: Data(json.utf8),
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        }
    }

    @Test
    func `by-api-key cost keeps a single currency`() throws {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let amountJSON = """
        {"code": 0, "data": {"biz_code": 0, "biz_data": {"series": []}}}
        """
        let costJSON = """
        {
          "code": 0,
          "data": {
            "biz_code": 0,
            "biz_data": {
              "data": [
                {"currency": "CNY", "series": [{"buckets": [{"time": \(day), "cost": "7"}]}]},
                {"currency": "USD", "series": [{"buckets": [{"time": \(day), "cost": "1"}]}]}
              ]
            }
          }
        }
        """
        let summary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(summary.currency == "USD")
        #expect(summary.todayCost == 1)
    }

    @Test
    func `by-api-key unknown response shape is rejected instead of reporting zero spend`() {
        let unrecognized = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"unrecognized":[]}}}"#.utf8)
        #expect {
            _ = try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: unrecognized,
                costData: unrecognized,
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test(arguments: [
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[],"function_series":[]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[]}}}"#,
    ])
    func `by-api-key explicit empty arrays succeed as valid empty period`(amountRaw: String) throws {
        let costRaw = #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[]}}}"#
        let summary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: Data(amountRaw.utf8),
            costData: Data(costRaw.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(summary.coverage?.requestedDays == 30)
        #expect(summary.coverage?.coveredDays == 30)
        #expect(summary.coverage?.isComplete == true)
        #expect(summary.currentMonthTokens == 0)
        #expect(summary.currentMonthRequestCount == 0)
        #expect(summary.currentMonthCost == 0.0)
        #expect(summary.todayCost == nil)
        #expect(summary.daily.isEmpty)
    }

    @Test(arguments: [
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"unrecognized":[]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":null}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"function_series":[]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"unrecognized":1}]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"buckets":[{"time":1779796800}]}]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[],"function_series":"bad"}}}"#,
    ])
    func `by-api-key rejects unrecognized or malformed amount payload when cost is valid`(badAmount: String) {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let validCost = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"currency":"USD","series":[
          {"api_key":"key-1","model":"deepseek-chat","buckets":[{"time":\(day),"cost":"1.25"}]}
        ]}]}}}
        """
        #expect {
            _ = try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: Data(badAmount.utf8),
                costData: Data(validCost.utf8),
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test(arguments: [
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"unrecognized":[]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":null}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"unrecognized":[]}]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"currency":"USD"}]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"currency":"  ","series":[]}]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"currency":"USD","series":[{"unrecognized":1}]}]}}}"#,
        """
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[
          {"currency":"USD","series":[{"buckets":[{"time":1779796800,"fee":"1.0"}]}]}
        ]}}}
        """,
    ])
    func `by-api-key rejects unrecognized or malformed cost payload when amount is valid`(badCost: String) {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let validAmount = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"api_key":"key-1","model":"deepseek-chat",
          "buckets":[{"time":\(day),"usage":{"RESPONSE_TOKEN":"100","REQUEST":"1"}}]}]}}}
        """
        #expect {
            _ = try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: Data(validAmount.utf8),
                costData: Data(badCost.utf8),
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test(arguments: [
        #"{"code":0,"data":{"biz_code":40002,"biz_data":{"unrecognized":[]}}}"#,
        #"{"code":40003,"data":"unexpected"}"#,
    ])
    func `by-api-key auth error survives unexpected payload shape`(authErrorJSON: String) {
        let validCost = #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[]}}}"#
        #expect {
            _ = try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: Data(authErrorJSON.utf8),
                costData: Data(validCost.utf8),
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `by-api-key merge with no covered chunks withholds period cost instead of fabricating zero`() {
        let plan = DeepSeekHistoryPlan.make(
            period: .rolling(days: 30),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        let summary = DeepSeekUsageCostParser.mergeByAPIKeyChunks([], plan: plan)
        #expect(summary.coverage?.coveredDays == 0)
        #expect(summary.coverage?.isComplete == false)
        #expect(summary.coverage?.isPartial == true)
        #expect(summary.coverage?.coveredIntervals.isEmpty == true)
        #expect(summary.currentMonthCost == nil)
        #expect(summary.todayCost == nil)
        let costSnapshot = summary.toCostUsageTokenSnapshot(calendar: self.fixtureCalendar)
        #expect(costSnapshot.last30DaysCostUSD == nil)
        #expect(costSnapshot.last30DaysTokens == nil)
        #expect(costSnapshot.last30DaysRequests == nil)
    }

    @Test
    func `by-api-key missing cost buckets withhold period and today cost instead of fabricating zero`() throws {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let amountJSON = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"api_key":"key-1","model":"deepseek-chat",
          "buckets":[{"time":\(day),"usage":{"RESPONSE_TOKEN":"100","REQUEST":"1"}}]}]}}}
        """
        let costJSON = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[
          {"currency":"USD","series":[{"api_key":"key-1","model":"deepseek-chat"}]}
        ]}}}
        """
        let summary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(summary.currentMonthTokens == 100)
        #expect(summary.currentMonthCost == nil)
        #expect(summary.todayCost == nil)
        #expect(summary.daily.first?.cost == nil)
        #expect(summary.modelCosts.isEmpty)
    }

    @Test
    func `by-api-key accepts exact Int.max totals and preserves requests, function calls, and sibling categories`()
        throws
    {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let amountJSON = """
        {"code":0,"data":{"biz_code":0,"biz_data":{
          "series":[{"api_key":"key-1","model":"deepseek-chat","buckets":[{"time":\(day),"usage":{
            "PROMPT_CACHE_HIT_TOKEN":"\(Int.max - 15)","PROMPT_CACHE_MISS_TOKEN":10,
            "RESPONSE_TOKEN":"5","REQUEST":"\(Int.max - 3)"}}]}],
          "function_series":[{"buckets":[{"time":\(day),"usage":{"FUNCTION_CALL":3}}]}]
        }}}
        """
        let costJSON = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"currency":"USD","series":[
          {"api_key":"key-1","model":"deepseek-chat","buckets":[{"time":\(day),"cost":"1.25"}]}]}]}}}
        """
        let summary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: Data(amountJSON.utf8),
            costData: Data(costJSON.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(summary.todayTokens == Int.max)
        #expect(summary.currentMonthTokens == Int.max)
        #expect(summary.requestCount == Int.max)
        #expect(summary.currentMonthRequestCount == Int.max)
        #expect(summary.topModel == "deepseek-chat")
        #expect(summary.categoryBreakdown.first { $0.category == .promptCacheHitToken }?.tokens == Int.max - 15)
        #expect(summary.categoryBreakdown.first { $0.category == .promptCacheMissToken }?.tokens == 10)
        #expect(summary.categoryBreakdown.first { $0.category == .responseToken }?.tokens == 5)
    }

    @Test(arguments: [
        "dayTokens", "siblingCategories", "requests", "functionCalls",
        "requestPlusFunctionCall", "scalarBeyondIntMax",
        "negToken", "negZeroToken", "fractionalToken", "nullToken", "negRequest", "negFunctionCall",
    ])
    func `by-api-key rejects within-window overflow and negative or non-integer counters`(scenario: String) {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let prev = day - 86400
        let maxMinus5 = Int.max - 5
        func singleSeries(_ buckets: String) -> String {
            #"{"series":[{"api_key":"k1","model":"deepseek-chat","buckets":[\#(buckets)]}]}"#
        }
        let bizData = switch scenario {
        case "dayTokens":
            singleSeries(
                #"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"\#(maxMinus5)"}},"#
                    + #"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"6"}}"#)
        case "siblingCategories":
            """
            {"series":[
              {"api_key":"k1","model":"deepseek-chat",
               "buckets":[{"time":\(day),"usage":{"PROMPT_CACHE_HIT_TOKEN":"\(maxMinus5)"}}]},
              {"api_key":"k2","model":"deepseek-reasoner",
               "buckets":[{"time":\(prev),"usage":{"RESPONSE_TOKEN":"6"}}]}]}
            """
        case "requests":
            singleSeries(
                #"{"time":\#(day),"usage":{"REQUEST":"\#(maxMinus5)"}},"#
                    + #"{"time":\#(prev),"usage":{"REQUEST":"6"}}"#)
        case "functionCalls":
            """
            {"series":[],"function_series":[{"buckets":[
              {"time":\(day),"usage":{"FUNCTION_CALL":"\(maxMinus5)"}},
              {"time":\(day),"usage":{"FUNCTION_CALL":"6"}}]}]}
            """
        case "requestPlusFunctionCall":
            """
            {"series":[{"api_key":"k1","model":"deepseek-chat",
              "buckets":[{"time":\(day),"usage":{"REQUEST":"\(Int.max - 2)"}}]}],
             "function_series":[{"buckets":[{"time":\(day),"usage":{"FUNCTION_CALL":"3"}}]}]}
            """
        case "scalarBeyondIntMax":
            singleSeries(#"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"9223372036854775808"}}"#)
        case "negToken":
            singleSeries(
                #"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"100"}},"#
                    + #"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"-50"}}"#)
        case "negZeroToken":
            singleSeries(#"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"-0"}}"#)
        case "fractionalToken":
            singleSeries(#"{"time":\#(day),"usage":{"RESPONSE_TOKEN":"12.5"}}"#)
        case "nullToken":
            singleSeries(#"{"time":\#(day),"usage":{"RESPONSE_TOKEN":null}}"#)
        case "negRequest":
            singleSeries(#"{"time":\#(day),"usage":{"REQUEST":-1}}"#)
        default:
            #"{"series":[],"function_series":[{"buckets":[{"time":\#(day),"usage":{"FUNCTION_CALL":"-2"}}]}]}"#
        }
        let amountJSON = #"{"code":0,"data":{"biz_code":0,"biz_data":\#(bizData)}}"#
        let costJSON = #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[]}}}"#
        #expect {
            _ = try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: Data(amountJSON.utf8),
                costData: Data(costJSON.utf8),
                now: self.fixtureNow,
                calendar: self.fixtureCalendar)
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `by-api-key and monthly parsers withhold negative costs and monthly enforces checked integer math`() throws {
        let day = Int(self.fixtureNow.timeIntervalSince1970)
        let byKeyAmount = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"api_key":"k1","model":"deepseek-chat",
          "buckets":[{"time":\(day),"usage":{"RESPONSE_TOKEN":"100","REQUEST":"1"}}]}]}}}
        """
        let byKeyNegCost = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[{"currency":"USD","series":[{"api_key":"k1",
          "model":"deepseek-chat","buckets":[{"time":\(day),"cost":"2.00"},{"time":\(day),"cost":"-1.50"}]}]}]}}}
        """
        let byKeySummary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: Data(byKeyAmount.utf8),
            costData: Data(byKeyNegCost.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(byKeySummary.todayTokens == 100)
        #expect(byKeySummary.todayCost == nil)
        #expect(byKeySummary.currentMonthCost == nil)
        #expect(byKeySummary.daily.first?.cost == nil)
        #expect(byKeySummary.modelCosts.isEmpty)

        let emptyCost = """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":[{"total":[],"days":[],"currency":"USD"}]}}
        """
        let exactMaxAmount = """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
          "total":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"\(Int.max - 5)"},{"type":"RESPONSE_TOKEN","amount":"5"}]}],
          "days":[
            {"date":"2026-05-25","data":[{"model":"deepseek-chat","usage":[
              {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"\(Int.max - 5)"}]}]},
            {"date":"2026-05-26","data":[{"model":"deepseek-chat","usage":[{"type":"RESPONSE_TOKEN","amount":"5"}]}]}]
        }}}
        """
        let exactSummary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(exactMaxAmount.utf8),
            costData: Data(emptyCost.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(exactSummary.currentMonthTokens == Int.max)
        #expect(exactSummary.todayTokens == 5)

        for badMonthly in [
            exactMaxAmount.replacingOccurrences(of: "\"5\"", with: "\"6\""),
            exactMaxAmount.replacingOccurrences(of: "\"5\"", with: "\"-5\""),
        ] {
            #expect {
                _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                    amountData: Data(badMonthly.utf8),
                    costData: Data(emptyCost.utf8),
                    now: self.fixtureNow,
                    calendar: self.fixtureCalendar)
            } throws: { error in
                guard case DeepSeekUsageError.parseFailed = error else { return false }
                return true
            }
        }

        let validAmount = """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
          "total":[{"model":"deepseek-chat","usage":[{"type":"RESPONSE_TOKEN","amount":"100"}]}],
          "days":[{"date":"2026-05-26","data":[{"model":"deepseek-chat","usage":[
            {"type":"RESPONSE_TOKEN","amount":"100"}]}]}]}}}
        """
        let negCost = """
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":[{"currency":"USD",
          "total":[{"model":"deepseek-chat","usage":[
            {"type":"RESPONSE_TOKEN","amount":"2.0"},{"type":"RESPONSE_TOKEN","amount":"-1.0"}]}],
          "days":[{"date":"2026-05-26","data":[{"model":"deepseek-chat","usage":[
            {"type":"RESPONSE_TOKEN","amount":"2.0"},{"type":"RESPONSE_TOKEN","amount":"-1.0"}]}]}]}]}}
        """
        let summaryWithNegCost = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: Data(validAmount.utf8),
            costData: Data(negCost.utf8),
            now: self.fixtureNow,
            calendar: self.fixtureCalendar)
        #expect(summaryWithNegCost.todayTokens == 100)
        #expect(summaryWithNegCost.todayCost == nil)
        #expect(summaryWithNegCost.currentMonthCost == nil)
        #expect(summaryWithNegCost.daily.first?.cost == nil)
        #expect(summaryWithNegCost.categoryBreakdown.first { $0.category == .responseToken }?.cost == nil)
    }
}

struct DeepSeekUsageCostParserAuthorizationTests {
    private static let emptyCostJSON = """
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

    @Test
    func `invalid platform token code requests a new web session`() {
        let amountJSON = """
        {
          "code": 40003,
          "msg": "Authorization Failed (invalid token)",
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
            "biz_data": []
          }
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(costJSON.utf8))
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `nested invalid platform token code requests a new web session`() {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 40002,
            "biz_msg": "Authorization Failed",
            "biz_data": null
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
            "biz_data": []
          }
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(costJSON.utf8))
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `top level authentication error survives an unexpected data shape`() {
        let amountJSON = """
        {
          "code": 40003,
          "msg": "Authorization Failed",
          "data": "unexpected"
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(Self.emptyCostJSON.utf8))
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `nested authentication error survives an unexpected biz data shape`() {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 40002,
            "biz_msg": "Authorization Failed",
            "biz_data": "unexpected"
          }
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(Self.emptyCostJSON.utf8))
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `successful malformed payload reports its decoding path`() {
        let amountJSON = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "total": "unexpected",
              "days": []
            }
          }
        }
        """

        #expect {
            _ = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
                amountData: Data(amountJSON.utf8),
                costData: Data(Self.emptyCostJSON.utf8))
        } throws: { error in
            guard case let DeepSeekUsageError.parseFailed(message) = error else { return false }
            return message.contains("total") && message.contains("typeMismatch")
        }
    }
}
