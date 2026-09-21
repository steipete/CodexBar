import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekModelCostTests {
    private let now = Date(timeIntervalSince1970: 1_779_796_800)

    private func parse(_ models: [(String?, [Any]?)], byKey: Bool) throws -> DeepSeekUsageSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let records: [[String: Any]] = models.enumerated().map { index, entry in
            var record: [String: Any] = [:]
            if let name = entry.0 { record["model"] = name }
            if byKey {
                record["api_key"] = "synthetic-\(index)"
                record["buckets"] = entry.1?.map { ["time": Int(self.now.timeIntervalSince1970), "cost": $0] }
            } else {
                record["usage"] = entry.1?.map { ["type": "RESPONSE_TOKEN", "amount": $0] }
            }
            return record
        }
        let amount = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["biz_data":
                byKey ? ["series": []] : ["total": [], "days": []]]])
        let block: [String: Any] = byKey
            ? ["currency": "USD", "series": records]
            : ["currency": "USD", "total": records, "days": []]
        let cost = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["biz_data":
                byKey ? ["data": [block]] as Any : [block]]])
        if byKey {
            return try DeepSeekUsageCostParser.parseByAPIKey(
                amountData: amount, costData: cost, now: self.now, calendar: calendar)
        }
        return try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: amount, costData: cost, now: self.now, calendar: calendar)
    }

    @Test(arguments: [false, true])
    func `model costs combine repeated names and sort by spend then name`(byKey: Bool) throws {
        let summary = try self.parse([
            ("example-beta", ["2"]), (" example-alpha ", ["1", "2"]),
            ("example-beta", ["1"]), ("example-zero", ["0"]),
            (nil, ["9"]), ("  ", ["8"]),
        ], byKey: byKey)
        #expect(summary.modelCosts == [
            DeepSeekModelCost(model: "example-alpha", cost: 3),
            DeepSeekModelCost(model: "example-beta", cost: 3),
            DeepSeekModelCost(model: "example-zero", cost: 0),
        ])
        #expect(summary.currency == "USD")
        #expect(summary.period == (byKey ? .last30Days : .currentMonth))
    }

    @Test(arguments: [false, true], ["invalid", "-1", "-1e-400", "NaN", "Infinity", "null", "overflow"])
    func `incomplete model totals are omitted without hiding valid zero`(byKey: Bool, invalid: String) throws {
        let amounts: [Any] = switch invalid {
        case "null": ["1", NSNull(), "2"]
        case "overflow": ["1e308", "1e308"]
        default: ["1", invalid, "2"]
        }
        let summary = try self.parse([
            ("example-invalid", amounts), ("example-invalid", ["4"]), ("example-zero", ["0"]),
        ], byKey: byKey)
        #expect(summary.modelCosts == [DeepSeekModelCost(model: "example-zero", cost: 0)])
    }

    @Test(arguments: [false, true])
    func `missing cost collections invalidate repeated model totals`(byKey: Bool) throws {
        let summary = try self.parse([
            ("example-incomplete", ["1"]), ("example-incomplete", nil), ("example-incomplete", ["2"]),
            ("example-complete", ["3"]), ("example-complete", []),
        ], byKey: byKey)
        #expect(summary.modelCosts == [DeepSeekModelCost(model: "example-complete", cost: 3)])
    }

    @Test
    func `model costs use the selected currency and exact reporting range`() throws {
        let time = Int(self.now.timeIntervalSince1970)
        let amount = Data(#"{"code":0,"data":{"biz_data":{"series":[]}}}"#.utf8)
        let cost = Data("""
        {"code":0,"data":{"biz_data":{"data":[
          {"currency":"CNY","series":[{"model":"example-foreign",
            "buckets":[{"time":\(time),"cost":"100"}]}]},
          {"currency":"USD","series":[{"model":"example-selected","buckets":[
            {"time":\(time - 1),"cost":"100"},
            {"time":\(time),"cost":"1"},
            {"time":\(time + 60),"cost":"2"},
            {"time":\(time + 120),"cost":"100"}]}]}
        ]}}}
        """.utf8)
        let summary = try DeepSeekUsageCostParser.parseByAPIKey(
            amountData: amount,
            costData: cost,
            now: self.now,
            rangeStart: self.now,
            rangeEnd: self.now.addingTimeInterval(120))
        #expect(summary.modelCosts == [DeepSeekModelCost(model: "example-selected", cost: 3)])
        #expect(summary.currentMonthCost == 3)
        #expect(summary.currency == "USD")
    }

    @Test
    func `unknown monthly cost types withhold only their model total`() throws {
        let amount = Data(#"{"code":0,"data":{"biz_data":{"total":[],"days":[]}}}"#.utf8)
        let cost = Data(#"""
        {"code":0,"data":{"biz_data":[{"currency":"USD","days":[],"total":[
          {"model":"example-unknown","usage":[
            {"type":"RESPONSE_TOKEN","amount":"1"},{"type":"UNKNOWN","amount":"2"}]},
          {"model":"example-missing","usage":[
            {"type":"RESPONSE_TOKEN","amount":"1"},{"amount":"2"}]},
          {"model":"example-known","usage":[
            {"type":"RESPONSE_TOKEN","amount":"3"},{"type":"REQUEST","amount":"100"}]}
        ]}]}}
        """#.utf8)
        let summary = try DeepSeekUsageFetcher._parseUsageSummaryForTesting(
            amountData: amount, costData: cost, now: self.now)
        #expect(summary.modelCosts == [DeepSeekModelCost(model: "example-known", cost: 3)])
    }
}
