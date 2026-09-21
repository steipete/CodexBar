import Foundation
import Testing
@testable import CodexBarCore

struct CodeRabbitUsageTests {
    @Test
    func `one CLI report supplies review and account data without a quota`() throws {
        let snapshot = try CodeRabbitUsageParser.parse(usageText: """
        CodeRabbit Usage — current billing period
        Organization  : Example Org
        Usage billing : inactive
        User          : example-user
        Your reviews  : 25
        Period resets : 2026-09-30
        """)
        let usage = snapshot.toUsageSnapshot()
        #expect(snapshot.reviewsCount == 25)
        #expect(snapshot.organization == "Example Org")
        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.identity?.loginMethod == nil)
        #expect(usage.identity?.accountOrganization == "Example Org")
        #expect(usage.identity?.accountID == "example-user")
        #expect(usage.details[0].rows.map(\.label) == ["Reviews", "Usage billing", "Period resets"])
        #expect(usage.details[0].rows.map(\.value) == ["25", "inactive", "2026-09-30"])
    }

    @Test
    func `blank fields cannot consume the following line`() throws {
        let snapshot = try CodeRabbitUsageParser.parse(usageText: """
        Organization :
        Usage billing : inactive
        User :
        Your reviews : 0
        Plan :
        Period resets : 2026-09-30 14:30:00
        """)
        #expect(snapshot.organization == nil)
        #expect(snapshot.user == nil)
        #expect(snapshot.plan == nil)
        #expect(snapshot.reviewsCount == 0)
        #expect(snapshot.usageBilling == "inactive")
        #expect(snapshot.periodResets == "2026-09-30 14:30:00")
    }

    @Test(arguments: ["Plan: Pro", "Organization: Example\nUser: example-user", "unexpected output"])
    func `account metadata cannot stand in for required usage`(output: String) {
        #expect(throws: CodeRabbitUsageError.parseFailed) {
            try CodeRabbitUsageParser.parse(usageText: output)
        }
    }

    @Test
    func `valid usage is not discarded because a help footer mentions login`() throws {
        let snapshot = try CodeRabbitUsageParser.parse(
            usageText: "Your reviews: 4\nTo switch accounts, run coderabbit auth login.")
        #expect(snapshot.reviewsCount == 4)
    }

    @Test
    func `signed-out output retains setup guidance`() {
        #expect(throws: CodeRabbitUsageError.notLoggedIn) {
            try CodeRabbitUsageParser.parse(usageText: "Please log in using coderabbit auth login.")
        }
    }

    @Test
    func `ANSI and CRLF reports retain line boundaries`() throws {
        let snapshot = try CodeRabbitUsageParser.parse(
            usageText: "\u{1B}[32mYour reviews\u{1B}[0m: 12\r\nUsage billing: active\r\n")
        #expect(snapshot.reviewsCount == 12)
        #expect(snapshot.usageBilling == "active")
    }

    @Test(arguments: ["-1", "999999999999999999999999999999999"])
    func `invalid review totals never become zero`(count: String) {
        #expect(throws: CodeRabbitUsageError.parseFailed) {
            try CodeRabbitUsageParser.parse(usageText: "Your reviews: \(count)")
        }
    }

    @Test
    func `probe accepts stderr reports without an auth enrichment command`() async throws {
        let probe = CodeRabbitCLIProbe(usageArguments: [
            "-c",
            "printf 'Fetching usage...\\n'; printf 'Your reviews: 10\\nUsage billing: inactive\\n' >&2",
        ])
        let snapshot = try await probe.fetch(environment: ["CODERABBIT_CLI_PATH": "/bin/sh"])
        #expect(snapshot.reviewsCount == 10)
        #expect(snapshot.usageBilling == "inactive")
        #expect(snapshot.plan == nil)
    }

    @Test
    func `nonzero commands cannot publish usage even when stdout looks valid`() async {
        let probe = CodeRabbitCLIProbe(usageArguments: ["-c", "printf 'Your reviews: 99\\n'; exit 9"])
        await #expect(throws: CodeRabbitUsageError.cliFailed(9)) {
            try await probe.fetch(environment: ["CODERABBIT_CLI_PATH": "/bin/sh"])
        }
    }

    @Test
    func `failed authentication stderr has provider login guidance`() async {
        let probe = CodeRabbitCLIProbe(usageArguments: [
            "-c", "printf 'Not authenticated. Run coderabbit auth login.\\n' >&2; exit 1",
        ])
        await #expect(throws: CodeRabbitUsageError.notLoggedIn) {
            try await probe.fetch(environment: ["CODERABBIT_CLI_PATH": "/bin/sh"])
        }
    }

    @Test
    func `an unusable explicit binary does not fall back to another installation`() {
        #expect(CodeRabbitCLIProbe.executable(
            environment: ["CODERABBIT_CLI_PATH": "/nonexistent-coderabbit-fixture", "PATH": "/bin"],
            loginPATH: ["/bin"]) == nil)
    }
}
