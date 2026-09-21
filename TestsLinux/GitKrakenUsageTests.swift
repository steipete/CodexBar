import Foundation
import Testing
@testable import CodexBarCore

struct GitKrakenUsageTests {
    private static let reset = "2026-09-27T00:00:00Z"

    private func api(
        used: Double = 12500,
        limit: Double = 400_000,
        extras: [String: Any] = [:]) throws -> GitKrakenUsage
    {
        var payload: [String: Any] = ["used": used, "limit": limit, "resetsOn": Self.reset]
        payload.merge(extras) { _, new in new }
        return try GitKrakenUsage.parseAPI(JSONSerialization.data(withJSONObject: ["data": payload, "error": NSNull()]))
    }

    @Test
    func `API maps personal and organization usage without double counting`() throws {
        let usage = try self.api(extras: [
            "organization": ["used": 20000, "limit": 100_000, "remaining": 80000],
            "sharedUsed": 5000,
        ])
        #expect(usage.unit == .credits)
        #expect(usage.personal.used == 12500)
        #expect(usage.personal.limit == 400_000)
        #expect(usage.organization?.used == 20000)
        #expect(usage.sharedUsed == 5000)
        #expect(usage.resetsAt == ISO8601DateFormatter().date(from: Self.reset))
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = usage.toUsageSnapshot(source: "API", now: now)
        #expect(snapshot.primary?.usedPercent == 3.125)
        #expect(snapshot.secondary?.usedPercent == 20)
        #expect(snapshot.primary?.windowMinutes == 10080)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.identity?.providerID == .gitkraken)
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.identity?.accountOrganization == nil)
    }

    @Test
    func `API does not invent an organization when it is absent`() throws {
        let usage = try self.api(extras: ["sharedUsed": 100])
        #expect(usage.organization == nil)
        #expect(usage.sharedUsed == nil)
        #expect(usage.toUsageSnapshot(source: "API").secondary == nil)
    }

    @Test
    func `malformed optional organization does not discard personal usage`() throws {
        for organization: Any in [
            NSNull(), "unavailable", ["used": 12], ["used": -1, "limit": 100],
            ["used": 12, "limit": -2], ["used": "12", "limit": 100],
        ] {
            let usage = try self.api(extras: ["organization": organization, "sharedUsed": 1])
            #expect(usage.personal.used == 12500)
            #expect(usage.organization == nil)
            #expect(usage.sharedUsed == nil)
        }
    }

    @Test
    func `invalid shared slice is omitted without losing the organization`() throws {
        for shared: Any in [-1, 201, "12", NSNull()] {
            let usage = try self.api(extras: [
                "organization": ["used": 200, "limit": 1000], "sharedUsed": shared,
            ])
            #expect(usage.organization?.used == 200)
            #expect(usage.sharedUsed == nil)
        }
        let zero = try self.api(extras: ["organization": ["used": 200, "limit": 1000], "sharedUsed": 0])
        #expect(zero.sharedUsed == 0)
    }

    @Test(arguments: [0.0, -1.0])
    func `sentinels have no invented utilization percentage`(limit: Double) throws {
        let usage = try self.api(used: 0, limit: limit, extras: ["organization": ["used": 0, "limit": limit]])
        #expect(usage.personal.usedPercent == nil)
        #expect(usage.personal.description(unit: .credits).contains(limit == 0 ? "No allowance" : "Unlimited"))
        let snapshot = usage.toUsageSnapshot(source: "API")
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(!snapshot.details.isEmpty)
    }

    @Test
    func `over quota and fractional usage are preserved`() throws {
        let usage = try self.api(used: 125.5, limit: 100)
        #expect(try abs(#require(usage.personal.usedPercent) - 125.5) < 1e-10)
        #expect(try abs(#require(usage.toUsageSnapshot(source: "API").primary?.usedPercent) - 125.5) < 1e-10)
    }

    @Test(arguments: [
        "{}", "null", "[]", "{\"data\":null}",
        "{\"used\":0,\"limit\":100,\"resetsOn\":\"2026-09-27T00:00:00Z\"}",
        "{\"data\":{\"used\":0,\"limit\":100}}",
        "{\"data\":{\"used\":true,\"limit\":100,\"resetsOn\":\"2026-09-27T00:00:00Z\"}}",
        "{\"data\":{\"used\":\"0\",\"limit\":100,\"resetsOn\":\"2026-09-27T00:00:00Z\"}}",
        "{\"data\":{\"used\":1e309,\"limit\":100,\"resetsOn\":\"2026-09-27T00:00:00Z\"}}",
    ])
    func `malformed primary API data is rejected`(json: String) {
        #expect(throws: GitKrakenUsageError.invalidResponse) {
            try GitKrakenUsage.parseAPI(Data(json.utf8))
        }
    }

    @Test(arguments: [-1.0, -100.0])
    func `negative usage is rejected`(used: Double) {
        #expect(throws: GitKrakenUsageError.invalidResponse) { try self.api(used: used) }
    }

    @Test(arguments: [-2.0, -0.5])
    func `unknown limit sentinels are rejected`(limit: Double) {
        #expect(throws: GitKrakenUsageError.invalidResponse) { try self.api(limit: limit) }
    }

    @Test
    func `percentage overflow is rejected`() {
        #expect(throws: GitKrakenUsageError.invalidResponse) {
            try GitKrakenUsage.Quota(used: .greatestFiniteMagnitude, limit: .leastNormalMagnitude)
        }
        #expect(throws: GitKrakenUsageError.invalidResponse) {
            try GitKrakenUsage.Quota(used: .nan, limit: 100)
        }
    }

    @Test
    func `non null API errors never publish accompanying data or leak error bodies`() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": ["used": 0, "limit": 100, "resetsOn": Self.reset],
            "error": ["message": "secret-response-fixture"],
        ])
        #expect(throws: GitKrakenUsageError.invalidResponse) { try GitKrakenUsage.parseAPI(data) }
        #expect(!GitKrakenUsageError.invalidResponse.localizedDescription.contains("secret-response-fixture"))
    }

    @Test(arguments: ["", "2026-09-27", "2026-09-27T00:00:00", "not-a-date"])
    func `API reset requires a timestamp with timezone`(reset: String) {
        #expect(throws: GitKrakenUsageError.invalidResponse) { try self.api(extras: ["resetsOn": reset]) }
    }

    @Test
    func `API accepts fractional seconds and timezone offsets`() throws {
        let fractional = try self.api(extras: ["resetsOn": "2026-09-27T00:00:00.000Z"])
        let offset = try self.api(extras: ["resetsOn": "2026-09-26T20:00:00-04:00"])
        #expect(fractional.resetsAt == offset.resetsAt)
    }

    @Test
    func `documented CLI tokens use exact counts rather than rounded percentage`() throws {
        let usage = try GitKrakenUsage.parseCLI("""
        24,443 of 4,000,000 tokens used (0% consumed)
        Reset on 08/17/2025
        """)
        #expect(usage.personal.used == 24443)
        #expect(usage.personal.limit == 4_000_000)
        #expect(usage.unit == .tokens)
        #expect(try #require(usage.personal.usedPercent) > 0.61)
        #expect(usage.resetsAt == nil)
        #expect(usage.resetDescription == "Resets on 08/17/2025")
        #expect(usage.organization == nil)
        #expect(usage.sharedUsed == nil)
    }

    @Test
    func `CLI with no unit does not claim credits`() throws {
        let usage = try GitKrakenUsage.parseCLI("12,510 of 250,000 used (5% consumed)\nReset on 04/05/2026")
        #expect(usage.unit == .allowance)
        #expect(!usage.personal.description(unit: usage.unit).contains("credits"))
        #expect(!usage.personal.description(unit: usage.unit).contains("tokens"))
        let snapshot = usage.toUsageSnapshot(source: "CLI")
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "CLI")
    }

    @Test
    func `CLI accepts explicitly reported credits ANSI color and CRLF`() throws {
        let usage = try GitKrakenUsage.parseCLI(
            "\u{001B}[32m1,250.5 of 400,000 credits used (0.31% consumed)\u{001B}[0m\r\nResets on 09/27/2026\r\n")
        #expect(usage.personal.used == 1250.5)
        #expect(usage.unit == .credits)
    }

    @Test(arguments: ["unlimited", "-1"])
    func `CLI unlimited allowance has no finite utilization`(limit: String) throws {
        let usage = try GitKrakenUsage.parseCLI("1 of \(limit) tokens used\nReset on 09/27/2026")
        #expect(usage.personal.limit == -1)
        #expect(usage.personal.usedPercent == nil)
    }

    @Test(arguments: [
        "Sign in to GitKraken", "", "{}",
        "24,44 of 100,000 used\nReset on 09/27/2026",
        "1 of 100 used", "Reset on 09/27/2026",
        "1 of 100 used\nReset on 02/30/2026",
        "1 of 100 used\nReset on 02/29/2025",
        "1 of 100 used\nReset on 2026-09-27",
        "1 of 100 used\n2 of 100 used\nReset on 09/27/2026",
        "1 of 100 used\nReset on 09/27/2026\nReset on 09/28/2026",
        "-1 of 100 used\nReset on 09/27/2026",
    ])
    func `unrecognized or ambiguous CLI output fails closed`(output: String) {
        #expect(throws: GitKrakenUsageError.invalidCLIOutput) { try GitKrakenUsage.parseCLI(output) }
    }

    @Test
    func `oversized input is rejected before parsing`() {
        #expect(throws: GitKrakenUsageError.responseTooLarge) {
            try GitKrakenUsage.parseAPI(Data(repeating: 32, count: 65537))
        }
        #expect(throws: GitKrakenUsageError.responseTooLarge) {
            try GitKrakenUsage.parseCLI(String(repeating: " ", count: 65537))
        }
    }
}
