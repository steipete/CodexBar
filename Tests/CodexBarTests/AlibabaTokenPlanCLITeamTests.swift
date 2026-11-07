import Foundation
import Testing
@testable import CodexBarCore

struct AlibabaTokenPlanCLITeamTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let cycleStart = 1_799_000_000_000.0
    private let cycleEnd = 1_801_000_000_000.0

    @Test
    func `Team credits aggregate distinct seats and use cycle reset instead of subscription expiry`() throws {
        let snapshot = try self.parse([
            self.seat("seat-a", total: 1000, remaining: 750),
            self.seat("seat-b", total: 2000, remaining: 1000),
        ])
        #expect(snapshot.totalQuota == 3000)
        #expect(snapshot.remainingQuota == 1750)
        #expect(snapshot.usedQuota == 1250)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: self.cycleEnd / 1000))
        #expect(snapshot.fiveHourUsedPercent == nil)
        #expect(snapshot.weeklyUsedPercent == nil)
        #expect(snapshot.planName == "Token Plan")
    }

    @Test
    func `different seat cycles omit an aggregate reset`() throws {
        let snapshot = try self.parse([
            self.seat("seat-a"),
            self.seat("seat-b", cycleEnd: self.cycleEnd + 1000),
        ])
        #expect(snapshot.totalQuota == 200)
        #expect(snapshot.resetsAt == nil)
    }

    @Test
    func `Team responses without usable credits fail for browser fallback`() throws {
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try self.parse([
                self.seat("refunded", status: "REFUNDED"),
                self.seat("expired", end: self.now.timeIntervalSince1970 * 1000),
                self.seat("future", start: self.now.timeIntervalSince1970 * 1000 + 1),
            ])
        }
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) { try self.parse([]) }
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try self.parse([self.seat("empty", total: 0, remaining: 0)])
        }
    }

    @Test
    func `duplicate seat identities never double count credits`() throws {
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try self.parse([self.seat("duplicate"), self.seat("duplicate")])
        }
    }

    @Test
    func `expired or future credit cycles are unavailable instead of counted`() throws {
        for end in [self.cycleStart, self.now.timeIntervalSince1970 * 1000] {
            #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
                try self.parse([self.seat("seat-a", cycleEnd: end)])
            }
        }
        var future = self.seat("seat-a")
        var equities = try #require(future["EquityList"] as? [[String: Any]])
        equities[0]["CycleStartTime"] = self.now.timeIntervalSince1970 * 1000 + 1
        future["EquityList"] = equities
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) { try self.parse([future]) }
    }

    @Test
    func `resource packs are not combined with credit equities`() throws {
        var seat = self.seat("seat-a")
        var equities = try #require(seat["EquityList"] as? [[String: Any]])
        var resource = equities[0]
        resource["EquityType"] = "RESOURCE_PACK"
        equities.append(resource)
        seat["EquityList"] = equities
        #expect(try self.parse([seat]).totalQuota == 100)
        equities.append(equities[0])
        seat["EquityList"] = equities
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) { try self.parse([seat]) }
    }

    @Test
    func `invalid credit counts are rejected without clamping`() throws {
        for (total, remaining) in [(-1.0, 0.0), (100.0, -1.0), (100.0, 101.0)] {
            #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
                try self.parse([self.seat("seat-a", total: total, remaining: remaining)])
            }
        }
        var seat = self.seat("seat-a")
        var equities = try #require(seat["EquityList"] as? [[String: Any]])
        equities[0]["CycleTotalValue"] = true
        seat["EquityList"] = equities
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) { try self.parse([seat]) }
    }

    @Test
    func `Team parsing rejects Personal output failed envelopes and inconsistent pagination`() throws {
        for data in try [
            Data(#"{"per1MonthPercentage":0.1}"#.utf8),
            self.pageData([], success: false),
            self.pageData([], total: 1001),
        ] {
            #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
                try AlibabaTokenPlanCLIUsageParser.teamPage(data, pageNo: 1)
            }
        }
        let page = try AlibabaTokenPlanCLIUsageParser.teamPage(self.pageData([], total: 1), pageNo: 1)
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try AlibabaTokenPlanCLIUsageParser.teamUsage([page], now: self.now)
        }
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try AlibabaTokenPlanCLIUsageParser.teamPage(self.pageData([]), pageNo: 2)
        }
    }

    @Test
    func `Team subprocess reads every page and sets a trusted endpoint for the selected region`() async throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(String(
            data: self.pageData((1...10).map { self.seat("seat-\($0)") }, total: 11), encoding: .utf8))
        let second = try #require(String(
            data: self.pageData([self.seat("seat-11")], total: 11, pageNo: 2), encoding: .utf8))
        let script = """
        #!/bin/sh
        printf '%s\\n' "$BAILIAN_BASE_URL" >> '\(directory.path)/base-url.txt'
        printf '%s\\n' "$DASHSCOPE_BASE_URL" >> '\(directory.path)/base-url.txt'
        printf '%s\\n' "$*" >> '\(directory.path)/arguments.txt'
        if [ "$4" = "1" ]; then
            printf '%s\\n' '\(first)'
        else
            printf '%s\\n' '\(second)'
        fi
        """
        try self.writeBinary(script, directory: directory)
        let snapshot = try await AlibabaTokenPlanCLIUsageFetcher.fetch(
            region: .international,
            environment: ["PATH": directory.path, "HOME": directory.path, "BAILIAN_BASE_URL": "https://untrusted.test"],
            now: self.now)
        #expect(snapshot.totalQuota == 1100)
        #expect(snapshot.remainingQuota == 550)
        let endpoints = try String(contentsOf: directory.appendingPathComponent("base-url.txt"), encoding: .utf8)
        #expect(endpoints == String(repeating: "https://dashscope-intl.aliyuncs.com\n", count: 4))
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments.txt"), encoding: .utf8)
        #expect(arguments.contains("--page-no 2"))
        #expect(!arguments.contains("--console-region"))
        #expect(!arguments.contains("usage token-plan"))
        #expect(AlibabaTokenPlanCLIUsageFetcher.teamBaseURL(region: .chinaMainland) == "https://dashscope.aliyuncs.com")
    }

    @Test
    func `Team subprocess rejects a truncated page instead of publishing partial quota`() async throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try #require(String(data: self.pageData([self.seat("seat-a")], total: 2), encoding: .utf8))
        try self.writeBinary("#!/bin/sh\nprintf '%s\\n' '\(response)'\n", directory: directory)
        await #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try await AlibabaTokenPlanCLIUsageFetcher.fetch(
                region: .chinaMainland, environment: ["PATH": directory.path, "HOME": directory.path], now: self.now)
        }
    }

    @Test
    func `Team authentication failure never echoes stderr`() async throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try self.writeBinary("#!/bin/sh\nprintf 'private-error' >&2\nexit 3\n", directory: directory)
        await #expect(throws: AlibabaTokenPlanCLIUsageError.commandFailed) {
            try await AlibabaTokenPlanCLIUsageFetcher.fetch(
                region: .chinaMainland, environment: ["PATH": directory.path, "HOME": directory.path], now: self.now)
        }
    }

    private func parse(_ seats: [[String: Any]]) throws -> AlibabaTokenPlanUsageSnapshot {
        let page = try AlibabaTokenPlanCLIUsageParser.teamPage(self.pageData(seats), pageNo: 1)
        return try AlibabaTokenPlanCLIUsageParser.teamUsage([page], now: self.now)
    }

    private func seat(
        _ id: String,
        total: Double = 100,
        remaining: Double = 50,
        status: String = "NORMAL",
        start: Double? = nil,
        end: Double? = nil,
        cycleEnd: Double? = nil) -> [String: Any]
    {
        [
            "SeatId": id, "Status": status, "StartTime": start ?? self.cycleStart,
            "EndTime": end ?? (self.cycleEnd + 1_000_000_000),
            "EquityList": [[
                "EquityType": "CREDITS", "CycleStartTime": self.cycleStart,
                "CycleEndTime": cycleEnd ?? self.cycleEnd,
                "CycleTotalValue": total, "CycleSurplusValue": remaining,
            ]],
        ]
    }

    private func pageData(
        _ seats: [[String: Any]], total: Int? = nil, pageNo: Int = 1, success: Bool = true) throws -> Data
    {
        try JSONSerialization.data(withJSONObject: [
            "Success": success,
            "Data": ["Items": seats, "Total": total ?? seats.count, "PageNo": pageNo, "PageSize": 10],
        ], options: [.sortedKeys])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailian-team-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeBinary(_ script: String, directory: URL) throws {
        let binary = directory.appendingPathComponent("bl")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    }
}
