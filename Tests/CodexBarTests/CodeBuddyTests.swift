import Foundation
import Testing

@testable import CodexBarCore

@Suite
struct CodeBuddyModelsTests {
    @Test
    func parseUsageResponse_validJSON_parsesCorrectly() throws {
        let json = """
        {
            "code": 0,
            "msg": "OK",
            "requestId": "e50a08a9-4c96-45f6-8d54-1b20914d5d29",
            "data": {
                "credit": 1121.44,
                "cycleStartTime": "2026-02-01 00:00:00",
                "cycleEndTime": "2026-02-28 23:59:59",
                "limitNum": 25000,
                "cycleResetTime": "2026-03-01 23:59:59"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodeBuddyUsageResponse.self, from: data)

        #expect(response.code == 0)
        #expect(response.msg == "OK")
        #expect(response.data.credit == 1121.44)
        #expect(response.data.limitNum == 25000)
        #expect(response.data.cycleStartTime == "2026-02-01 00:00:00")
        #expect(response.data.cycleEndTime == "2026-02-28 23:59:59")
        #expect(response.data.cycleResetTime == "2026-03-01 23:59:59")
    }

    @Test
    func parseDailyUsageResponse_validJSON_parsesCorrectly() throws {
        let json = """
        {
            "code": 0,
            "msg": "OK",
            "requestId": "74093760-b510-4955-aa64-2013958f7aba",
            "data": {
                "total": 7,
                "data": [
                    {"credit": 387.84, "date": "2026-02-03"},
                    {"credit": 278.86, "date": "2026-02-02"},
                    {"credit": 129.25, "date": "2026-01-31"}
                ]
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodeBuddyDailyUsageResponse.self, from: data)

        #expect(response.code == 0)
        #expect(response.data.total == 7)
        #expect(response.data.data.count == 3)
        #expect(response.data.data[0].credit == 387.84)
        #expect(response.data.data[0].date == "2026-02-03")
    }
}

@Suite
struct CodeBuddyUsageSnapshotTests {
    @Test
    func toUsageSnapshot_calculatesPercentageCorrectly() {
        let snapshot = CodeBuddyUsageSnapshot(
            creditUsed: 1000,
            creditLimit: 10000,
            cycleStartTime: "2026-02-01 00:00:00",
            cycleEndTime: "2026-02-28 23:59:59",
            cycleResetTime: "2026-03-01 23:59:59",
            updatedAt: Date())

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary?.usedPercent == 10.0)
        #expect(usageSnapshot.identity?.providerID == .codebuddy)
    }

    @Test
    func toUsageSnapshot_handlesZeroLimit() {
        let snapshot = CodeBuddyUsageSnapshot(
            creditUsed: 100,
            creditLimit: 0,
            cycleStartTime: "2026-02-01 00:00:00",
            cycleEndTime: "2026-02-28 23:59:59",
            cycleResetTime: "2026-03-01 23:59:59",
            updatedAt: Date())

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary?.usedPercent == 0.0)
    }

    @Test
    func toUsageSnapshot_formatsResetDescription() {
        let snapshot = CodeBuddyUsageSnapshot(
            creditUsed: 1121.44,
            creditLimit: 25000,
            cycleStartTime: "2026-02-01 00:00:00",
            cycleEndTime: "2026-02-28 23:59:59",
            cycleResetTime: "2026-03-01 23:59:59",
            updatedAt: Date())

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary?.resetDescription?.contains("1,121") == true)
        #expect(usageSnapshot.primary?.resetDescription?.contains("25,000") == true)
    }
}

@Suite
struct CodeBuddyCookieHeaderTests {
    @Test
    func extractEnterpriseID_fromCurlCommand() {
        let curl = """
        curl 'https://tencent.sso.codebuddy.cn/billing/meter/get-enterprise-user-usage' \\
          -H 'x-enterprise-id: etahzsqej0n4' \\
          --data-raw '{}'
        """

        let enterpriseID = CodeBuddyCookieHeader.extractEnterpriseID(from: curl)

        #expect(enterpriseID == "etahzsqej0n4")
    }

    @Test
    func extractEnterpriseID_fromHeader() {
        let header = "x-enterprise-id: abc123xyz"

        let enterpriseID = CodeBuddyCookieHeader.extractEnterpriseID(from: header)

        #expect(enterpriseID == "abc123xyz")
    }

    @Test
    func override_fromCookieHeader() {
        let cookieHeader = "session=abc123; session_2=xyz789"

        let override = CodeBuddyCookieHeader.override(from: cookieHeader)

        #expect(override != nil)
        #expect(override?.cookieHeader == cookieHeader)
    }

    @Test
    func override_fromEmptyString_returnsNil() {
        let override = CodeBuddyCookieHeader.override(from: "")

        #expect(override == nil)
    }

    @Test
    func override_fromNil_returnsNil() {
        let override = CodeBuddyCookieHeader.override(from: nil)

        #expect(override == nil)
    }
}
