import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct KiroStatusProbeTests {
    // MARK: - Happy Path Parsing

    @Test
    func parsesBasicUsageOutput() throws {
        let output = """
        | KIRO FREE                                          |
        ████████████████████████████████████████████████████ 25%
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsPercent == 25)
        #expect(snapshot.creditsUsed == 12.50)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.bonusCreditsUsed == nil)
        #expect(snapshot.bonusCreditsTotal == nil)
        #expect(snapshot.bonusExpiryDays == nil)
        #expect(snapshot.resetsAt != nil)
    }

    @Test
    func parsesOutputWithBonusCredits() throws {
        let output = """
        | KIRO PRO                                           |
        ████████████████████████████████████████████████████ 80%
        (40.00 of 50 covered in plan), resets on 02/01
        Bonus credits: 5.00/10 credits used, expires in 7 days
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO PRO")
        #expect(snapshot.creditsPercent == 80)
        #expect(snapshot.creditsUsed == 40.00)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.bonusCreditsUsed == 5.00)
        #expect(snapshot.bonusCreditsTotal == 10)
        #expect(snapshot.bonusExpiryDays == 7)
    }

    @Test
    func parsesOutputWithoutPercentFallbacksToCreditsRatio() throws {
        let output = """
        | KIRO FREE                                          |
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.creditsPercent == 25)
    }

    @Test
    func parsesBonusCreditsWithoutExpiry() throws {
        let output = """
        | KIRO FREE                                          |
        ████████████████████████████████████████████████████ 60%
        (30.00 of 50 covered in plan), resets on 04/01
        Bonus credits: 2.00/5 credits used
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.bonusCreditsUsed == 2.0)
        #expect(snapshot.bonusCreditsTotal == 5.0)
        #expect(snapshot.bonusExpiryDays == nil)
    }

    @Test
    func parsesOutputWithANSICodes() throws {
        let output = """
        \u{001B}[32m| KIRO FREE                                          |\u{001B}[0m
        \u{001B}[38;5;11m████████████████████████████████████████████████████\u{001B}[0m 50%
        (25.00 of 50 covered in plan), resets on 03/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsPercent == 50)
        #expect(snapshot.creditsUsed == 25.00)
        #expect(snapshot.creditsTotal == 50)
    }

    @Test
    func parsesOutputWithSingleDay() throws {
        let output = """
        | KIRO FREE                                          |
        ████████████████████████████████████████████████████ 10%
        (5.00 of 50 covered in plan)
        Bonus credits: 2.00/5 credits used, expires in 1 day
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.bonusExpiryDays == 1)
    }

    @Test
    func rejectsOutputMissingUsageMarkers() throws {
        let output = """
        | KIRO FREE                                          |
        """

        let probe = KiroStatusProbe()
        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: output)
        }
    }

    // MARK: - New Format (kiro-cli 1.24+, Q Developer)

    @Test
    func parsesQDeveloperManagedPlan() throws {
        let output = """
        Plan: Q Developer Pro
        Your plan is managed by admin

        Tip: to see context window usage, run /context
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Pro")
        #expect(snapshot.creditsPercent == 0)
        #expect(snapshot.creditsUsed == 0)
        #expect(snapshot.creditsTotal == 0)
        #expect(snapshot.bonusCreditsUsed == nil)
        #expect(snapshot.resetsAt == nil)
    }

    @Test
    func parsesQDeveloperFreePlan() throws {
        let output = """
        Plan: Q Developer Free
        Your plan is managed by admin
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Free")
        #expect(snapshot.creditsPercent == 0)
    }

    @Test
    func parsesNewFormatWithANSICodes() throws {
        let output = """
        \u{001B}[38;5;141mPlan: Q Developer Pro\u{001B}[0m
        Your plan is managed by admin
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Pro")
    }

    @Test
    func rejectsHeaderOnlyNewFormatWithoutManagedMarker() {
        let output = """
        Plan: Q Developer Pro
        Tip: to see context window usage, run /context
        """

        let probe = KiroStatusProbe()
        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: output)
        }
    }

    @Test
    func preservesParsedUsageForManagedPlanWithMetrics() throws {
        let output = """
        Plan: Q Developer Enterprise
        Your plan is managed by admin
        ████████████████████████████████████████████████████ 40%
        (20.00 of 50 covered in plan), resets on 03/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Enterprise")
        #expect(snapshot.creditsPercent == 40)
        #expect(snapshot.creditsUsed == 20)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.resetsAt != nil)
    }

    // MARK: - Snapshot Conversion

    @Test
    func convertsSnapshotToUsageSnapshot() throws {
        let now = Date()
        let resetDate = try #require(Calendar.current.date(byAdding: .day, value: 7, to: now))

        let snapshot = KiroUsageSnapshot(
            planName: "KIRO PRO",
            creditsUsed: 25.0,
            creditsTotal: 100.0,
            creditsPercent: 25.0,
            bonusCreditsUsed: 5.0,
            bonusCreditsTotal: 20.0,
            bonusExpiryDays: 14,
            resetsAt: resetDate,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25.0)
        #expect(usage.primary?.resetsAt == resetDate)
        #expect(usage.secondary?.usedPercent == 25.0) // 5/20 * 100
        #expect(usage.loginMethod(for: .kiro) == "KIRO PRO")
        #expect(usage.accountOrganization(for: .kiro) == "KIRO PRO")
    }

    @Test
    func convertsSnapshotWithoutBonusCredits() {
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO FREE",
            creditsUsed: 10.0,
            creditsTotal: 50.0,
            creditsPercent: 20.0,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            resetsAt: nil,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20.0)
        #expect(usage.secondary == nil)
    }

    // MARK: - Error Cases

    @Test
    func emptyOutputThrowsParseError() {
        let probe = KiroStatusProbe()

        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: "")
        }
    }

    @Test
    func warningOutputThrowsParseError() {
        let output = """
        \u{001B}[38;5;11m⚠️  Warning: Could not retrieve usage information from backend
        \u{001B}[38;5;8mError: dispatch failure (io error): an i/o error occurred
        """

        let probe = KiroStatusProbe()

        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: output)
        }
    }

    @Test
    func unrecognizedFormatThrowsParseError() {
        // Simulates a CLI format change where none of the expected patterns match
        let output = """
        Welcome to Kiro!
        Your account is active.
        Usage: unknown format
        """

        let probe = KiroStatusProbe()

        #expect {
            try probe.parse(output: output)
        } throws: { error in
            guard case let KiroStatusProbeError.parseError(msg) = error else { return false }
            return msg.contains("No recognizable usage patterns")
        }
    }

    @Test
    func loginPromptThrowsNotLoggedIn() {
        let output = """
        Failed to initialize auth portal.
        Please try again with: kiro-cli login --use-device-flow
        error: OAuth error: All callback ports are in use.
        """

        let probe = KiroStatusProbe()

        #expect {
            try probe.parse(output: output)
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    // MARK: - WhoAmI Validation

    @Test
    func whoamiNotLoggedInThrows() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "Not logged in", stderr: "", terminationStatus: 1)
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func whoamiLoginRequiredThrows() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "login required", stderr: "", terminationStatus: 1)
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func whoamiEmptyOutputWithZeroStatusThrows() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "", stderr: "", terminationStatus: 0)
        } throws: { error in
            guard case KiroStatusProbeError.cliFailed = error else { return false }
            return true
        }
    }

    @Test
    func whoamiNonZeroStatusWithMessageThrows() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "", stderr: "Connection error", terminationStatus: 1)
        } throws: { error in
            guard case KiroStatusProbeError.cliFailed = error else { return false }
            return true
        }
    }

    @Test
    func whoamiSuccessDoesNotThrow() throws {
        let probe = KiroStatusProbe()

        try probe.validateWhoAmIOutput(
            stdout: "user@example.com",
            stderr: "",
            terminationStatus: 0)
    }
}
