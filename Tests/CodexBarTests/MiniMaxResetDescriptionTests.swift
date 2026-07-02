import Foundation
import Testing
@testable import CodexBarCore

private enum MiniMaxResetDescriptionTestIntervals {
    static let twoHoursThirtyFourMinutes: TimeInterval = 9240
    static let threeDaysFiveHoursTwelveMinutes: TimeInterval = 277_920
    static let twoHoursFifteenMinutesMillis = 8_100_000
    static let twoHoursMillis = 7_200_000
    static let fiveHoursMillis = 18_000_000
}

struct MiniMaxResetDescriptionTests {
    @Test
    func `countdown phrase includes minutes for multi hour windows`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetsAt = now.addingTimeInterval(MiniMaxResetDescriptionTestIntervals.twoHoursThirtyFourMinutes)

        #expect(MiniMaxServiceUsage.resetCountdownPhrase(from: resetsAt, now: now) == "2 hours 34 minutes")
        #expect(
            MiniMaxServiceUsage
                .generateResetDescription(resetsAt: resetsAt, now: now) == "Resets in 2 hours 34 minutes")
    }

    @Test
    func `countdown phrase includes days hours and minutes for weekly windows`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetsAt = now.addingTimeInterval(MiniMaxResetDescriptionTestIntervals.threeDaysFiveHoursTwelveMinutes)

        #expect(
            MiniMaxServiceUsage.resetCountdownPhrase(from: resetsAt, now: now) == "3 days 5 hours 12 minutes")
    }

    @Test
    func `countdown phrase rounds up partial minutes`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resetsAt = now.addingTimeInterval(61)

        #expect(MiniMaxServiceUsage.resetCountdownPhrase(from: resetsAt, now: now) == "2 minutes")
    }

    @Test
    func `coding plan service reset description matches end time precision`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + MiniMaxResetDescriptionTestIntervals.twoHoursFifteenMinutesMillis
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "MiniMax-M1",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end)
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let service = try #require(snapshot.services?.first)

        #expect(service.resetDescription == "Resets in 2 hours 15 minutes")
    }

    @Test
    func `reset description prefers remains time over window end`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + MiniMaxResetDescriptionTestIntervals.twoHoursMillis
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "MiniMax-M1",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "remains_time": 8100000
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let service = try #require(snapshot.services?.first)

        #expect(service.resetDescription == "Resets in 2 hours 15 minutes")
    }

    @Test
    func `five hour reset ignores implausible remains time`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + MiniMaxResetDescriptionTestIntervals.fiveHoursMillis
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_total_count": 100,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 100,
              "start_time": \(start),
              "end_time": \(end),
              "remains_time": 950400000
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)
        let service = try #require(services.first { $0.windowType == "5 hours" })

        #expect(service.resetsAt == Date(timeIntervalSince1970: TimeInterval(end) / 1000))
        #expect(service.resetDescription == "Resets in 5 hours")
    }
}
