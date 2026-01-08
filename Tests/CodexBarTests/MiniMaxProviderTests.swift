import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct MiniMaxUsageParserTests {
    @Test
    func parsesCodingPlanRemainsResponse() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [
            {
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "remains_time": 240000
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let expectedReset = Date(timeIntervalSince1970: TimeInterval(end) / 1000)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1000)
        #expect(snapshot.currentPrompts == 750)  // 1000 - 250
        #expect(snapshot.remainingPrompts == 250)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.usedPercent == 75)  // 750 used / 1000 total
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func parsesCodingPlanRemainsFromDataWrapper() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": "0" },
          "data": {
            "current_subscribe_title": "Max",
            "model_remains": [
              {
                "current_interval_total_count": "15000",
                "current_interval_usage_count": "14989",
                "start_time": \(start),
                "end_time": \(end),
                "remains_time": 8941292
              }
            ]
          }
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let expectedUsed = Double(11) / Double(15000) * 100
        let expectedReset = Date(timeIntervalSince1970: TimeInterval(end) / 1000)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 15000)
        #expect(snapshot.currentPrompts == 11)  // 15000 - 14989
        #expect(snapshot.remainingPrompts == 14989)
        #expect(snapshot.windowMinutes == 300)
        #expect(abs((snapshot.usedPercent ?? 0) - expectedUsed) < 0.01)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func throwsOnMissingCookieResponse() {
        let json = """
        {
          "base_resp": { "status_code": 1004, "status_msg": "cookie is missing, log in again" }
        }
        """

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8))
        }
    }

    @Test
    func throwsOnStringStatusCodeWhenLoggedOut() {
        let json = """
        {
          "base_resp": { "status_code": "1004", "status_msg": "login required" }
        }
        """

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8))
        }
    }

    @Test
    func throwsOnErrorInDataWrapper() {
        let json = """
        {
          "data": {
            "base_resp": { "status_code": 1004, "status_msg": "unauthorized" }
          }
        }
        """

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8))
        }
    }
}
