import CodexBarCore
import Foundation
import Testing

struct WindsurfStatusProbeTests {
    // MARK: - Helper

    private static func decode(_ json: String) throws -> WindsurfCachedPlanInfo {
        try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(json.utf8))
    }

    // MARK: - JSON Decoding

    @Test
    func `decodes full plan info`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "startTimestamp": 1771610750000,
          "endTimestamp": 1774029950000,
          "usage": {
            "messages": 50000,
            "usedMessages": 35650,
            "remainingMessages": 14350,
            "flowActions": 150000,
            "usedFlowActions": 0,
            "remainingFlowActions": 150000
          },
          "quotaUsage": {
            "dailyRemainingPercent": 9,
            "weeklyRemainingPercent": 54,
            "dailyResetAtUnix": 1774080000,
            "weeklyResetAtUnix": 1774166400
          }
        }
        """)

        #expect(info.planName == "Pro")
        #expect(info.startTimestamp == 1_771_610_750_000)
        #expect(info.endTimestamp == 1_774_029_950_000)
        #expect(info.usage?.messages == 50000)
        #expect(info.usage?.usedMessages == 35650)
        #expect(info.usage?.remainingMessages == 14350)
        #expect(info.usage?.flowActions == 150_000)
        #expect(info.usage?.usedFlowActions == 0)
        #expect(info.usage?.remainingFlowActions == 150_000)
        #expect(info.quotaUsage?.dailyRemainingPercent == 9)
        #expect(info.quotaUsage?.weeklyRemainingPercent == 54)
        #expect(info.quotaUsage?.dailyResetAtUnix == 1_774_080_000)
        #expect(info.quotaUsage?.weeklyResetAtUnix == 1_774_166_400)
    }

    @Test
    func `decodes minimal plan info`() throws {
        let info = try Self.decode("""
        {"planName": "Free"}
        """)

        #expect(info.planName == "Free")
        #expect(info.usage == nil)
        #expect(info.quotaUsage == nil)
        #expect(info.endTimestamp == nil)
    }

    @Test
    func `decodes empty object`() throws {
        let info = try Self.decode("{}")

        #expect(info.planName == nil)
        #expect(info.usage == nil)
        #expect(info.quotaUsage == nil)
    }

    // MARK: - toUsageSnapshot Conversion

    @Test
    func `converts full plan to usage snapshot`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "startTimestamp": 1771610750000,
          "endTimestamp": 1774029950000,
          "usage": {
            "messages": 50000, "usedMessages": 35650, "remainingMessages": 14350,
            "flowActions": 150000, "usedFlowActions": 0, "remainingFlowActions": 150000
          },
          "quotaUsage": {
            "dailyRemainingPercent": 9, "weeklyRemainingPercent": 54,
            "dailyResetAtUnix": 1774080000, "weeklyResetAtUnix": 1774166400
          }
        }
        """)

        let snapshot = info.toUsageSnapshot()

        // Primary = daily: usedPercent = 100 - 9 = 91
        #expect(snapshot.primary?.usedPercent == 91)
        #expect(snapshot.primary?.resetsAt != nil)

        // Secondary = weekly: usedPercent = 100 - 54 = 46
        #expect(snapshot.secondary?.usedPercent == 46)
        #expect(snapshot.secondary?.resetsAt != nil)

        // Identity
        #expect(snapshot.identity?.providerID == .windsurf)
        #expect(snapshot.identity?.loginMethod == "Pro")
        #expect(snapshot.identity?.accountOrganization != nil)
    }

    @Test
    func `converts minimal plan to usage snapshot`() throws {
        let info = try Self.decode("""
        {"planName": "Free"}
        """)

        let snapshot = info.toUsageSnapshot()

        // Without quotaUsage, primary and secondary should be nil
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Free")
        #expect(snapshot.identity?.accountOrganization == nil)
    }

    @Test
    func `daily at zero remaining shows 100 percent used`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "quotaUsage": {"dailyRemainingPercent": 0, "weeklyRemainingPercent": 100}
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 0)
    }

    @Test
    func `weekly at full remaining shows 0 percent used`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "quotaUsage": {"dailyRemainingPercent": 100, "weeklyRemainingPercent": 100}
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.secondary?.usedPercent == 0)
    }

    @Test
    func `reset dates are correctly converted from unix timestamps`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "quotaUsage": {
            "dailyRemainingPercent": 50, "weeklyRemainingPercent": 50,
            "dailyResetAtUnix": 1774080000, "weeklyResetAtUnix": 1774166400
          }
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_774_080_000))
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_774_166_400))
    }

    @Test
    func `end timestamp converts to expiry description`() throws {
        let futureMs = Int64(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000)
        let info = try Self.decode("""
        {"planName": "Pro", "endTimestamp": \(futureMs)}
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.identity?.accountOrganization?.hasPrefix("Expires ") == true)
    }

    // MARK: - Probe Error Cases

    @Test
    func `probe throws dbNotFound for missing file`() {
        let probe = WindsurfStatusProbe(dbPath: "/nonexistent/path/state.vscdb")

        #expect(throws: WindsurfStatusProbeError.self) {
            _ = try probe.fetch()
        }
    }
}
