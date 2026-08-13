import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekRollingUsageParserTests {
    @Test
    func `rolling amount sums token categories across api keys models and buckets`() throws {
        let data = Data(Self.amountJSON.utf8)

        let tokens = try DeepSeekRollingUsageParser.parseAmount(data)

        #expect(tokens == 250)
    }

    @Test
    func `rolling cost selects the requested currency and sums every series`() throws {
        let data = Data(Self.costJSON.utf8)

        let result = try DeepSeekRollingUsageParser.parseCost(data, preferredCurrency: "USD")

        #expect(result.currency == "USD")
        #expect(abs(result.cost - 1.75) < 0.000_001)
    }

    @Test
    func `rolling usage keeps whichever endpoint remains available`() {
        let amountOnly = DeepSeekUsageFetcher._parseRollingUsageForTesting(
            amountData: Data(Self.amountJSON.utf8),
            costData: Data("not-json".utf8))
        let costOnly = DeepSeekUsageFetcher._parseRollingUsageForTesting(
            amountData: nil,
            costData: Data(Self.costJSON.utf8),
            preferredCurrency: "CNY")

        #expect(amountOnly?.tokens == 250)
        #expect(amountOnly?.cost == nil)
        #expect(costOnly?.tokens == nil)
        #expect(costOnly?.currency == "CNY")
        #expect(abs((costOnly?.cost ?? 0) - 3.5) < 0.000_001)
    }

    @Test
    func `rolling parser maps nested platform authentication errors`() {
        let data = Data(#"{"code":0,"data":{"biz_code":40003,"biz_data":"unexpected"}}"#.utf8)

        #expect {
            try DeepSeekRollingUsageParser.parseAmount(data)
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `rolling ranges cover exactly five hours and seven days`() {
        let now = Date(timeIntervalSince1970: 1_784_224_800.75)

        let ranges = DeepSeekUsageFetcher._rollingUsageRangesForTesting(now: now)

        #expect(ranges.end == 1_784_224_800)
        #expect(ranges.end - ranges.fiveHourStart == 5 * 60 * 60)
        #expect(ranges.end - ranges.weeklyStart == 7 * 24 * 60 * 60)
    }

    private static let amountJSON = """
    {
      "code": 0,
      "data": {
        "biz_code": 0,
        "biz_data": {
          "start": 1784199600,
          "end": 1784224800,
          "bucket": 3600,
          "models": ["deepseek-chat", "deepseek-reasoner"],
          "series": [
            {
              "api_key": {"tracking_id":"one","name":"One","sensitive_id":"sk-1","valid":true},
              "model": "deepseek-chat",
              "buckets": [
                {
                  "time": 1784199600,
                  "usage": {
                    "PROMPT_CACHE_HIT_TOKEN": "100",
                    "PROMPT_CACHE_MISS_TOKEN": 20,
                    "PROMPT_TOKEN": "5",
                    "RESPONSE_TOKEN": "30",
                    "REQUEST": 99
                  }
                }
              ]
            },
            {
              "api_key": {"tracking_id":"two","name":"Two","sensitive_id":"sk-2","valid":true},
              "model": "deepseek-reasoner",
              "buckets": [
                {
                  "time": 1784203200,
                  "usage": {
                    "PROMPT_CACHE_HIT_TOKEN": 40,
                    "PROMPT_CACHE_MISS_TOKEN": "10",
                    "RESPONSE_TOKEN": 45,
                    "REQUEST": "2"
                  }
                }
              ]
            }
          ]
        }
      }
    }
    """

    private static let costJSON = """
    {
      "code": 0,
      "data": {
        "biz_code": 0,
        "biz_data": {
          "start": 1784199600,
          "end": 1784224800,
          "bucket": 3600,
          "models": ["deepseek-chat"],
          "data": [
            {
              "currency": "CNY",
              "series": [
                {"model":"deepseek-chat","buckets":[{"time":1784199600,"cost":"1.25"}]},
                {"model":"deepseek-chat","buckets":[{"time":1784203200,"cost":2.25}]}
              ]
            },
            {
              "currency": "USD",
              "series": [
                {"model":"deepseek-chat","buckets":[{"time":1784199600,"cost":"0.50"}]},
                {"model":"deepseek-chat","buckets":[{"time":1784203200,"cost":"1.25"}]}
              ]
            }
          ]
        }
      }
    }
    """
}
