import Foundation
import Testing
@testable import CodexBarCore

struct KiroUsageLimitsAPITests {
    /// Captured from a live `GetUsageLimits` response for a KIRO POWER account whose plan credits
    /// were fully spent and whose overage was in use. Account identifiers are scrubbed.
    static let overageInUseResponse = """
    {"daysUntilReset":0,"limits":[],"nextDateReset":1.7882208E9,
     "overageConfiguration":{"__type":"com.amazon.aws.codewhisperer#OverageConfiguration",
       "overageStatus":"ENABLED"},
     "subscriptionInfo":{"overageCapability":"OVERAGE_CAPABLE","subscriptionTitle":"KIRO POWER",
       "type":"Q_DEVELOPER_STANDALONE_POWER"},
     "usageBreakdownList":[{"bonuses":[],"currency":"USD","currentOverages":3603,
       "currentOveragesWithPrecision":3603.49,"currentUsage":13603,
       "currentUsageWithPrecision":13603.49,"displayName":"Credit","nextDateReset":1.7882208E9,
       "overageCap":10000,"overageCapWithPrecision":10000.0,"overageCharges":144.139711109352,
       "overageCredits":[],"overageRate":0.04,"resourceType":"CREDIT","unit":"INVOCATIONS",
       "usageLimit":10000,"usageLimitWithPrecision":10000.0}]}
    """

    @Test
    func `parses plan and overage without double counting spend`() throws {
        let limits = try KiroUsageLimitsAPI.parse(Data(Self.overageInUseResponse.utf8))

        // `currentUsage` is the total including overage; the plan portion is the remainder.
        #expect(limits.planLimit == 10000)
        #expect(limits.planUsed == 10000)
        #expect(limits.overageUsed == 3603.49)
        #expect(limits.overageCap == 10000)
        #expect(limits.overageEnabled == true)
        #expect(limits.overageCharges == 144.139711109352)
        #expect(limits.overageRate == 0.04)
        #expect(limits.currencyCode == "USD")
        #expect(limits.overageChargeLimit == 400)
        #expect(limits.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test
    func `rejects overage that exceeds total usage`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(
                of: "\"currentUsageWithPrecision\":13603.49",
                with: "\"currentUsageWithPrecision\":100")
        #expect(throws: KiroUsageLimitsError.self) {
            try KiroUsageLimitsAPI.parse(Data(json.utf8))
        }
    }

    @Test
    func `keeps overage that exceeds the overage cap`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(
                of: "\"overageCapWithPrecision\":10000.0",
                with: "\"overageCapWithPrecision\":100")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))
        #expect(limits.overageCap == 100)
        #expect(limits.overageUsed == 3603.49)
    }

    @Test
    func `treats overage as unavailable when the account has it disabled`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(of: "\"overageStatus\":\"ENABLED\"", with: "\"overageStatus\":\"DISABLED\"")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))

        #expect(limits.overageCap == nil)
        #expect(limits.overageEnabled == false)
        #expect(limits.overageChargeLimit == nil)
        // Disabling overage does not un-spend it: `currentUsage` still includes those credits, so
        // the plan portion stays the remainder and never reads above the plan limit.
        #expect(limits.overageUsed == 3603.49)
        #expect(limits.planUsed == 10000)
        #expect(limits.planUsed <= limits.planLimit)
    }

    @Test
    func `rejects a reset outside plausible unix seconds`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(of: "\"nextDateReset\":1.7882208E9", with: "\"nextDateReset\":1.7882208E12")
        #expect(throws: KiroUsageLimitsError.self) {
            try KiroUsageLimitsAPI.parse(Data(json.utf8))
        }
    }

    @Test
    func `rejects several credit balances`() throws {
        // Two CREDIT rows leave no single authoritative ceiling, so neither may be picked.
        let json = """
        {"nextDateReset":1.7882208E9,"usageBreakdownList":[
          {"resourceType":"CREDIT","currentUsageWithPrecision":1.0,"usageLimitWithPrecision":10.0},
          {"resourceType":"CREDIT","currentUsageWithPrecision":2.0,"usageLimitWithPrecision":20.0}]}
        """
        #expect(throws: KiroUsageLimitsError.self) {
            try KiroUsageLimitsAPI.parse(Data(json.utf8))
        }
    }

    @Test
    func `snapshot surfaces the overage window and charges against their ceilings`() throws {
        let limits = try KiroUsageLimitsAPI.parse(Data(Self.overageInUseResponse.utf8))
        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%
        """)
        let snapshot = cliReport.withUsageLimits(limits).toUsageSnapshot()

        // The plan gauge must exclude overage, or 13603.49/10000 would read as 136%.
        #expect(snapshot.primary?.usedPercent == 100)
        let overage = try #require(snapshot.extraRateWindows?.first { $0.id == "kiro-overage" })
        #expect(overage.title == "Overage")
        #expect(abs(overage.window.usedPercent - 36.0349) < 0.0001)
        let cost = try #require(snapshot.providerCost)
        #expect(cost.used == 144.139711109352)
        #expect(cost.limit == 400)
        #expect(cost.currencyCode == "USD")

        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Overages" && $0.value == "Enabled" })
        #expect(rows.contains { $0.label == "Overage usage" && $0.value == "3603.49 credits" })
        #expect(rows.contains { $0.label == "Overage credits left" && $0.value == "6396.51" })
    }

    @Test
    func `refuses the live state database under tests`() async {
        await #expect(throws: KiroUsageLimitsError.self) {
            try await KiroUsageLimitsAPI.fetch()
        }
    }

    @Test
    func `cli report stands when the usage api is unavailable`() throws {
        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-06-01 | KIRO FREE
        Credits (0.17 of 50 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 0%
        Overages: Disabled
        """)
        let snapshot = cliReport.withUsageLimits(nil).toUsageSnapshot()

        #expect(cliReport.creditsUsed == 0.17)
        #expect(cliReport.creditsTotal == 50)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.providerCost == nil)
    }

    @Test
    func `api disabled overage wins over a stale cli enabled status`() throws {
        let limits = try KiroUsageLimitsAPI.parse(Data(
            Self.overageInUseResponse
                .replacingOccurrences(of: "\"overageStatus\":\"ENABLED\"", with: "\"overageStatus\":\"DISABLED\"")
                .utf8))
        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%
        Overages: Enabled billed at $0.04 per request
        """)
        let snapshot = cliReport.withUsageLimits(limits).toUsageSnapshot()
        let rows = snapshot.details.flatMap(\.rows)

        #expect(limits.overageCap == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.providerCost == nil)
        #expect(rows.contains { $0.label == "Overages" && $0.value == "Disabled" })
        #expect(rows.contains { $0.label == "Overage usage" } == false)
        #expect(rows.contains { $0.label == "Overage credits left" } == false)
    }

    @Test
    func `rejects plan usage above the reported plan limit`() {
        let json = Self.overageInUseResponse
            .replacingOccurrences(
                of: "\"currentOveragesWithPrecision\":3603.49",
                with: "\"currentOveragesWithPrecision\":0")
        #expect(throws: KiroUsageLimitsError.self) {
            try KiroUsageLimitsAPI.parse(Data(json.utf8))
        }
    }

    @Test
    func `unknown overage status is not treated as disabled`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(
                of: "\"overageStatus\":\"ENABLED\"",
                with: "\"overageStatus\":\"FUTURE_STATUS\"")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))
        #expect(limits.overageEnabled == nil)
        #expect(limits.overageCap == nil)

        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%
        Overages: Enabled billed at $0.04 per request
        """)
        let snapshot = cliReport.withUsageLimits(limits).toUsageSnapshot()
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Overages" && $0.value.hasPrefix("Enabled") })
        #expect(rows.contains { $0.label == "Overage usage" })
    }

    @Test
    func `enabled overage without a cap keeps cli overage rows`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(of: "\"overageCapWithPrecision\":10000.0,", with: "")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))
        #expect(limits.overageEnabled == nil)
        #expect(limits.overageCap == nil)
        #expect(limits.overageUsed == 3603.49)

        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%
        Overages: Enabled billed at $0.04 per request
        """)
        let snapshot = cliReport.withUsageLimits(limits).toUsageSnapshot()
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Overages" && $0.value.hasPrefix("Enabled") })
        #expect(rows.contains { $0.label == "Overage usage" })
        #expect(rows.contains { $0.label == "Overage credits left" } == false)
    }

    @Test
    func `bonus entries keep cli plan usage instead of mixing them into the plan gauge`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(of: "\"bonuses\":[]", with: "\"bonuses\":[{}]")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))
        #expect(limits.hasUnseparatedBonus)
        #expect(limits.overageUsed == 3603.49)

        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (40.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 0%
        Bonus credits: 5.00/10 credits used
        Overages: Enabled billed at $0.04 per request
        """)
        let snapshot = cliReport.withUsageLimits(limits)
        #expect(snapshot.creditsUsed == 40)
        #expect(snapshot.creditsTotal == 10000)
        #expect(snapshot.bonusCreditsUsed == 5)
        #expect(snapshot.overageCreditsUsed == 3603.49)
        let rows = snapshot.toUsageSnapshot().details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Overage usage" })
    }

    @Test
    func `bonus-inclusive usage above the plan limit still enriches overage`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(of: "\"bonuses\":[]", with: "\"bonuses\":[{}]")
            .replacingOccurrences(
                of: "\"currentUsageWithPrecision\":13603.49",
                with: "\"currentUsageWithPrecision\":14603.49")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))
        #expect(limits.hasUnseparatedBonus)
        #expect(limits.planUsed == 11000)
        #expect(limits.overageUsed == 3603.49)
        #expect(limits.overageCap == 10000)

        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (40.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 0%
        Bonus credits: 5.00/10 credits used
        Overages: Enabled billed at $0.04 per request
        """)
        let snapshot = cliReport.withUsageLimits(limits)
        #expect(snapshot.creditsUsed == 40)
        #expect(snapshot.creditsTotal == 10000)
        #expect(snapshot.overageCreditsUsed == 3603.49)
    }

    @Test
    func `non usd api without charges does not keep the cli usd estimate`() throws {
        let json = Self.overageInUseResponse
            .replacingOccurrences(of: "\"currency\":\"USD\"", with: "\"currency\":\"EUR\"")
            .replacingOccurrences(of: "\"overageCharges\":144.139711109352,", with: "")
        let limits = try KiroUsageLimitsAPI.parse(Data(json.utf8))
        #expect(limits.currencyCode == "EUR")
        #expect(limits.overageCharges == nil)

        let probe = KiroStatusProbe()
        let cliReport = try probe.parse(output: """
        Estimated Usage | resets on 2026-09-01 | KIRO POWER
        Credits (10000.00 of 10000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%

        Overages: Enabled billed at $0.04 per request
        Credits used: 40.29
        Est. cost: $1.61 USD
        """)
        #expect(cliReport.estimatedOverageCostUSD == 1.61)

        let snapshot = cliReport.withUsageLimits(limits)
        #expect(snapshot.estimatedOverageCostUSD == nil)
        #expect(snapshot.usageLimits?.currencyCode == "EUR")
    }

    @Test
    func `resolves kiro cli state database per platform and overrides`() {
        let home = URL(fileURLWithPath: "/tmp/codexbar-kiro-home", isDirectory: true)
        let mac = KiroUsageLimitsAPI.stateDatabaseURL(
            homeDirectory: home,
            environment: [:],
            usesMacOSApplicationSupport: true)
        #expect(mac.path == "/tmp/codexbar-kiro-home/Library/Application Support/kiro-cli/data.sqlite3")

        let linux = KiroUsageLimitsAPI.stateDatabaseURL(
            homeDirectory: home,
            environment: [:],
            usesMacOSApplicationSupport: false)
        #expect(linux.path == "/tmp/codexbar-kiro-home/.local/share/kiro-cli/data.sqlite3")

        let xdg = KiroUsageLimitsAPI.stateDatabaseURL(
            homeDirectory: home,
            environment: ["XDG_DATA_HOME": "/tmp/xdg-data"],
            usesMacOSApplicationSupport: false)
        #expect(xdg.path == "/tmp/xdg-data/kiro-cli/data.sqlite3")

        let override = KiroUsageLimitsAPI.stateDatabaseURL(
            homeDirectory: home,
            environment: ["KIRO_DATA_DIR": "/tmp/kiro-data"],
            usesMacOSApplicationSupport: true)
        #expect(override.path == "/tmp/kiro-data/data.sqlite3")
    }

    @Test
    func `fetch enriches plan and overage from the usage api`() async throws {
        let limits = try KiroUsageLimitsAPI.parse(Data(Self.overageInUseResponse.utf8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-limits-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
          printf 'Estimated Usage | resets on 2026-09-01 | KIRO POWER\\n'
          printf 'Credits (10000.00 of 10000 covered in plan)\\n'
          printf '████████████████████████████████████████████████████████████████████████████████ 100%%\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
          exit 0
        fi
        exit 1
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        let snapshot = try await KiroStatusProbe(
            cliBinaryResolver: { cliURL.path },
            usageLimitsFetcher: { limits }).fetch()
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.creditsUsed == 10000)
        #expect(snapshot.overageCreditsUsed == 3603.49)
        #expect(snapshot.usageLimits?.overageCap == 10000)
        #expect(usage.extraRateWindows?.contains { $0.id == "kiro-overage" } == true)
        #expect(usage.providerCost?.limit == 400)
    }

    @Test
    func `cancellation during usage limits enrichment is preserved`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-limits-cancel-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
          printf 'Estimated Usage | resets on 2026-09-01 | KIRO POWER\\n'
          printf 'Credits (10000.00 of 10000 covered in plan)\\n'
          printf '████████████████████████████████████████████████████████████████████████████████ 100%%\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
          exit 0
        fi
        exit 1
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        await #expect(throws: CancellationError.self) {
            try await KiroStatusProbe(
                cliBinaryResolver: { cliURL.path },
                usageLimitsFetcher: { throw CancellationError() }).fetch()
        }
    }
}
