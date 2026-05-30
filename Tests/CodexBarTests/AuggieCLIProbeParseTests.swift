import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)

struct AuggieCLIProbeParseTests {
    private let probe = AuggieCLIProbe()

    @Test
    func `parses current auggie account status output`() throws {
        let output = """
        ╭ Account ───────────────────────────────────────────────╮
        │                                                        │
        │ 319,054 credits remaining                     Max Plan │
        │                                450,000 credits / month │
        │                                                        │
        ╰────────────────────────────────────────────────────────╯

         9 days remaining in this billing cycle (ends 6/9/2026)
         For more detail, visit https://app.augmentcode.com/account
        """

        let snapshot = try probe.parse(output)

        #expect(snapshot.creditsRemaining == 319_054)
        #expect(snapshot.creditsLimit == 450_000)
        #expect(snapshot.creditsUsed == 130_946)
        #expect(snapshot.accountPlan == "450,000 credits/month")
        #expect(snapshot.billingCycleEnd != nil)
    }

    @Test
    func `parses legacy auggie account status output`() throws {
        let output = """
        Max Plan 450,000 credits / month
        11,657 remaining · 953,170 / 964,827 credits used
        2 days remaining in this billing cycle (ends 1/8/2026)
        """

        let snapshot = try probe.parse(output)

        #expect(snapshot.creditsRemaining == 11657)
        #expect(snapshot.creditsUsed == 953_170)
        #expect(snapshot.creditsLimit == 964_827)
        #expect(snapshot.accountPlan == "450,000 credits/month")
    }
}

#endif
