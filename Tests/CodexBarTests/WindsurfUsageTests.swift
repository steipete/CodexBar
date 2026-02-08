import CodexBarCore
import Foundation
import Testing

@Suite
struct WindsurfUsageTests {
    @Test
    func decodesCachedPlanInfoAndBuildsUsageSnapshot() throws {
        // Build representative JSON without embedding large numeric literals in a multiline string,
        // which SwiftFormat can lint for grouping.
        let obj: [String: Any] = [
            "planName": "Pro",
            "startTimestamp": 1_735_689_600,
            "endTimestamp": 1_738_368_000,
            "usage": [
                "messages": 500,
                "flowActions": 200,
                "flexCredits": 1000,
                "usedMessages": 125,
                "usedFlowActions": 50,
                "usedFlexCredits": 250,
                "remainingMessages": 375,
                "remainingFlowActions": 150,
                "remainingFlexCredits": 750,
            ],
            "hasBillingWritePermissions": true,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: obj)
        let info = try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: jsonData)
        let snap = try WindsurfLocalStorageReader.makeUsageSnapshot(info: info, now: Date(timeIntervalSince1970: 0))

        #expect(snap.primary?.usedPercent.rounded() == 25)
        #expect(snap.secondary?.usedPercent.rounded() == 25)
        #expect(snap.tertiary?.usedPercent.rounded() == 25)
        #expect(snap.loginMethod(for: .windsurf) == "Pro")
        #expect(snap.accountEmail(for: .windsurf) == nil)
    }

    @Test
    func parseEpochSupportsSecondsAndMilliseconds() {
        let seconds = WindsurfLocalStorageReader.parseEpoch(1_738_368_000)
        let millis = WindsurfLocalStorageReader.parseEpoch(1_738_368_000_000)
        #expect(seconds != nil)
        #expect(millis != nil)
        #expect(abs((seconds?.timeIntervalSince1970 ?? 0) - (millis?.timeIntervalSince1970 ?? 0)) < 1.0)
    }

    @Test
    func omitsWindowsWhenTotalsAreZero() throws {
        let info = WindsurfCachedPlanInfo(
            planName: "Free",
            startTimestamp: 1,
            endTimestamp: 2,
            usage: WindsurfPlanUsage(
                duration: nil,
                messages: 0,
                flowActions: 0,
                flexCredits: 0,
                usedMessages: 0,
                usedFlowActions: 0,
                usedFlexCredits: 0,
                remainingMessages: 0,
                remainingFlowActions: 0,
                remainingFlexCredits: 0),
            hasBillingWritePermissions: nil)

        let snap = try WindsurfLocalStorageReader.makeUsageSnapshot(info: info, now: Date())
        #expect(snap.primary == nil)
        #expect(snap.secondary == nil)
        #expect(snap.tertiary == nil)
    }
}
