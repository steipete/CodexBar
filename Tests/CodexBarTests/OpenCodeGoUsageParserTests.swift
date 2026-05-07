import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeGoUsageParserTests {
    @Test
    func `parses workspace ids`() {
        let text = ";0x00000089;((self.$R=self.$R||{})[\"codexbar\"]=[]," +
            "($R=>$R[0]=[$R[1]={id:\"wrk_01K6AR1ZET89H8NB691FQ2C2VB\",name:\"Default\",slug:null}])" +
            "($R[\"codexbar\"]))"
        let ids = OpenCodeGoUsageFetcher.parseWorkspaceIDs(text: text)
        #expect(ids == ["wrk_01K6AR1ZET89H8NB691FQ2C2VB"])
    }

    @Test
    func `parses subscription usage from seroval response`() throws {
        let text =
            "$R[16]($R[30],$R[41]={rollingUsage:$R[42]={status:\"ok\",resetInSec:5944,usagePercent:17}," +
            "weeklyUsage:$R[43]={status:\"ok\",resetInSec:278201,usagePercent:75}," +
            "monthlyUsage:$R[44]={status:\"ok\",resetInSec:880201,usagePercent:91}});"
        let now = Date(timeIntervalSince1970: 0)

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.weeklyUsagePercent == 75)
        #expect(snapshot.hasMonthlyUsage == true)
        #expect(snapshot.monthlyUsagePercent == 91)
        #expect(snapshot.rollingResetInSec == 5944)
        #expect(snapshot.weeklyResetInSec == 278_201)
        #expect(snapshot.monthlyResetInSec == 880_201)
    }

    @Test
    func `parses subscription usage from live go page hydration`() throws {
        let rollingResetInSec = 17591
        let weeklyResetInSec = 444_552
        let monthlyResetInSec = 2_591_424
        let text =
            "_$HY.r[\"lite.subscription.get[\\\"wrk_LIVE123\\\"]\"]=$R[17]=$R[2]($R[18]={p:0,s:0,f:0});" +
            "$R[24]($R[18],$R[27]={mine:!0,useBalance:!1," +
            "rollingUsage:$R[28]={status:\"ok\",resetInSec:\(rollingResetInSec),usagePercent:0}," +
            "weeklyUsage:$R[29]={status:\"ok\",resetInSec:\(weeklyResetInSec),usagePercent:0}," +
            "monthlyUsage:$R[30]={status:\"ok\",resetInSec:\(monthlyResetInSec),usagePercent:0}});"
        let now = Date(timeIntervalSince1970: 0)

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)

        #expect(snapshot.rollingUsagePercent == 0)
        #expect(snapshot.weeklyUsagePercent == 0)
        #expect(snapshot.hasMonthlyUsage == true)
        #expect(snapshot.monthlyUsagePercent == 0)
        #expect(snapshot.rollingResetInSec == rollingResetInSec)
        #expect(snapshot.weeklyResetInSec == weeklyResetInSec)
        #expect(snapshot.monthlyResetInSec == monthlyResetInSec)
    }

    @Test
    func `parses subscription from JSON with reset at and ratio percentages`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rollingResetAt = now.addingTimeInterval(3600)
        let monthlyResetAt = now.addingTimeInterval(86400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "usage": [
                "rollingUsage": [
                    "usagePercent": 0.25,
                    "resetAt": formatter.string(from: rollingResetAt),
                ],
                "weeklyUsage": [
                    "usagePercent": 75,
                    "resetInSec": 7200,
                ],
                "monthlyUsage": [
                    "usagePercent": 0.9,
                    "resetAt": formatter.string(from: monthlyResetAt),
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 75)
        #expect(snapshot.hasMonthlyUsage == true)
        #expect(snapshot.monthlyUsagePercent == 90)
        #expect(snapshot.rollingResetInSec == 3600)
        #expect(snapshot.weeklyResetInSec == 7200)
        #expect(snapshot.monthlyResetInSec == 86400)
    }

    @Test
    func `computes usage percent from totals and treats monthly as optional`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload: [String: Any] = [
            "rollingUsage": [
                "used": 25,
                "limit": 100,
                "resetInSec": 600,
            ],
            "weeklyUsage": [
                "used": 50,
                "limit": 200,
                "resetInSec": 3600,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 25)
        #expect(snapshot.hasMonthlyUsage == false)
        #expect(snapshot.monthlyUsagePercent == 0)
        #expect(snapshot.monthlyResetInSec == 0)
        #expect(usage.tertiary == nil)
    }

    @Test
    func `parses subscription from nested candidate windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload: [String: Any] = [
            "windows": [
                "primaryWindow": [
                    "used": 15,
                    "limit": 100,
                    "resetInSec": 600,
                ],
                "weeklyQuota": [
                    "used": 80,
                    "limit": 200,
                    "resetInSec": 7200,
                ],
                "monthlyBucket": [
                    "used": 90,
                    "limit": 300,
                    "resetInSec": 86400,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)

        #expect(snapshot.rollingUsagePercent == 15)
        #expect(snapshot.weeklyUsagePercent == 40)
        #expect(snapshot.hasMonthlyUsage == true)
        #expect(snapshot.monthlyUsagePercent == 30)
        #expect(snapshot.monthlyResetInSec == 86400)
    }

    @Test
    func `candidate fallback does not fabricate weekly from non weekly windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload: [String: Any] = [
            "windows": [
                "primaryWindow": [
                    "used": 15,
                    "limit": 100,
                    "resetInSec": 600,
                ],
                "monthlyBucket": [
                    "used": 90,
                    "limit": 300,
                    "resetInSec": 86400,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)
        }
    }

    @Test
    func `clamps invalid percentages`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload: [String: Any] = [
            "rollingUsage": [
                "usagePercent": 150,
                "resetInSec": 60,
            ],
            "weeklyUsage": [
                "usagePercent": -10,
                "resetInSec": 120,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? ""

        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)

        #expect(snapshot.rollingUsagePercent == 100)
        #expect(snapshot.weeklyUsagePercent == 0)
    }

    @Test
    func `parse subscription throws when required fields are missing`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = "{\"monthlyUsage\":{\"usagePercent\":50,\"resetInSec\":123}}"

        #expect(throws: OpenCodeGoUsageError.self) {
            _ = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: now)
        }
    }
}
