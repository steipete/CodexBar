import Testing
@testable import CodexBarCore

struct KiroPlanNameTests {
    @Test(arguments: [
        "| KIRO PRO+                                          |",
        "┃ | KIRO PRO+ ┃",
        "Estimated Usage | resets on 2026-12-01 | KIRO PRO+",
        "Plan: KIRO PRO+",
        "Plan: KIRO PRO+ | 1 usage breakdowns",
        "\u{001B}[1mEstimated Usage\u{001B}[0m | resets on 2026-12-01 | \u{001B}[32mKIRO PRO+\u{001B}[0m",
    ])
    func `plan names preserve the plus through parsing and snapshot conversion`(header: String) throws {
        let snapshot = try KiroStatusProbe().parse(output: """
        \(header)
        Credits (500 of 2000 covered in plan)
        """)

        #expect(snapshot.planName == "KIRO PRO+")
        #expect(snapshot.displayPlanName == "Kiro Pro+")
        #expect(snapshot.toUsageSnapshot().detailRow(label: "Plan")?.value == "Kiro Pro+")
    }
}
