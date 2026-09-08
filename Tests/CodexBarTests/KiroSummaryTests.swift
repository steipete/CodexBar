import Foundation
import Testing
@testable import CodexBarCore

struct KiroSummaryTests {
    @Test(arguments: ["0", "1", "2"])
    func `summary preserves the plan without inventing usage`(count: String) throws {
        let snapshot = try KiroStatusProbe().parse(
            output: "\u{001B}[32mPlan: KIRO PRO MAX | \(count) usage breakdowns\u{001B}[0m\n")
        #expect(snapshot.planName == "KIRO PRO MAX")
        Self.expectPlanOnly(snapshot.toUsageSnapshot())
    }

    @Test
    func `managed plan without metrics does not publish zero usage`() throws {
        let snapshot = try KiroStatusProbe().parse(output: """
        Plan: Q Developer Pro
        Your plan is managed by admin
        """)
        Self.expectPlanOnly(snapshot.toUsageSnapshot())
    }

    @Test(arguments: [
        "Plan: KIRO PRO MAX",
        "Plan: KIRO PRO MAX | usage breakdowns",
        "Plan: KIRO PRO MAX | -1 usage breakdowns",
        "Plan: KIRO PRO MAX | 1.5 usage breakdowns",
        "Plan: KIRO PRO MAX | 1 usage breakdowns failed",
        "Plan: | 1 usage breakdowns",
        "echo Plan: KIRO PRO MAX | 1 usage breakdowns",
        "Plan: KIRO PRO MAX |\n1 usage breakdowns",
    ])
    func `incomplete and malformed summaries remain errors`(output: String) {
        #expect(throws: KiroStatusProbeError.self) {
            try KiroStatusProbe().parse(output: output)
        }
    }

    @Test
    func `summary with real zero usage keeps the reported allowance`() throws {
        let snapshot = try KiroStatusProbe().parse(output: """
        Plan: KIRO PRO MAX | 1 usage breakdowns
        Credits (0 of 5000 covered in plan)
        """)
        #expect(snapshot.planName == "KIRO PRO MAX")
        #expect(snapshot.creditsTotal == 5000)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 0)
        #expect(snapshot.toUsageSnapshot().details.flatMap(\.rows).contains { $0.label == "Credits total" })
    }

    @Test(arguments: [false, true])
    func `CLI summary reaches optional enrichment and survives its failure`(apiSucceeds: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("kiro-cli")
        try """
        #!/bin/sh
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
          printf 'Plan: KIRO PRO MAX | 1 usage breakdowns\\n'
          exit 0
        fi
        if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
          exit 0
        fi
        exit 1
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let snapshot = try await KiroStatusProbe(
            cliBinaryResolver: { cli.path },
            usageLimitsFetcher: {
                guard apiSucceeds else { throw KiroUsageLimitsError.requestFailed("Synthetic unavailable API") }
                return Self.limits()
            }).fetch()
        let usage = snapshot.toUsageSnapshot()
        #expect(snapshot.planName == "KIRO PRO MAX")
        #expect(snapshot.accountEmail == "person@example.com")
        if apiSucceeds {
            #expect(snapshot.creditsUsed == 282.49)
            #expect(snapshot.creditsTotal == 5000)
            #expect(abs((usage.primary?.usedPercent ?? -1) - 5.6498) < 0.0001)
        } else {
            Self.expectPlanOnly(usage)
        }
    }

    @Test
    func `ambiguous bonus enrichment cannot invent a plan gauge`() throws {
        let snapshot = try KiroStatusProbe().parse(output: "Plan: KIRO PRO MAX | 1 usage breakdowns")
        Self.expectPlanOnly(snapshot.withUsageLimits(Self.limits(hasUnseparatedBonus: true)).toUsageSnapshot())
    }

    @Test
    func `zero API allowance preserves unknown or existing CLI metrics`() throws {
        let unknown = try KiroStatusProbe().parse(output: "Plan: KIRO PRO MAX | 1 usage breakdowns")
        Self.expectPlanOnly(unknown.withUsageLimits(Self.limits(planLimit: 0)).toUsageSnapshot())
        let known = try KiroStatusProbe().parse(output: "Credits (20 of 50 covered in plan)")
            .withUsageLimits(Self.limits(planLimit: 0))
        #expect(known.creditsUsed == 20)
        #expect(known.creditsTotal == 50)
        #expect(known.toUsageSnapshot().primary?.usedPercent == 40)
    }

    private static func expectPlanOnly(_ snapshot: UsageSnapshot) {
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.details.flatMap(\.rows).map(\.label) == ["Plan"])
    }

    private static func limits(hasUnseparatedBonus: Bool = false, planLimit: Double = 5000) -> KiroUsageLimits {
        KiroUsageLimits(
            planLimit: planLimit,
            planUsed: planLimit == 0 ? 0 : 282.49,
            overageUsed: 0,
            overageCap: nil,
            overageCharges: nil,
            overageRate: nil,
            currencyCode: "USD",
            resetsAt: Date(timeIntervalSince1970: 1_790_812_800),
            hasUnseparatedBonus: hasUnseparatedBonus)
    }
}
