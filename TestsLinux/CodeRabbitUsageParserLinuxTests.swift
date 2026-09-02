import CodexBarCore
import Foundation
import Testing

@Suite
struct CodeRabbitUsageParserLinuxTests {
    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date
        }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return try #require(dateOnly.date(from: value))
    }

    @Test
    func `parses standard coderabbit usage text`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let output = """
        - Fetching usage for the current billing period...
        ────────────────────────────────────────
        CodeRabbit Usage — current billing period

        Organization  : MonkeyMed
        Usage billing : inactive
        User          : MonkeyMed
        Your reviews  : 25
        Period resets : 2026-09-30
        ────────────────────────────────────────
        """

        let snapshot = try CodeRabbitUsageParser.parse(usageText: output, now: now)

        #expect(snapshot.organization == "MonkeyMed")
        #expect(snapshot.usageBilling == "inactive")
        #expect(snapshot.user == "MonkeyMed")
        #expect(snapshot.reviewsCount == 25)
        #expect(snapshot.periodResetsRaw == "2026-09-30")
        #expect(try snapshot.periodResets == self.date("2026-09-30"))
        #expect(snapshot.updatedAt == now)

        let usage = snapshot.toUsageSnapshot(now: now)
        #expect(usage.primary == nil)
        #expect(usage.subscriptionRenewsAt == snapshot.periodResets)
        #expect(usage.identity?.accountOrganization == "MonkeyMed")
        #expect(usage.identity?.loginMethod == "25 reviews")
        #expect(usage.detailRow(label: "Reviews")?.value == "25")
        #expect(usage.detailRow(label: "Organization")?.value == "MonkeyMed")
        #expect(usage.detailRow(label: "Usage billing")?.value == "inactive")
        #expect(usage.detailRow(label: "Period resets")?.value == "2026-09-30")
    }

    @Test
    func `parses coderabbit usage combined with auth status text`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usageOutput = """
        ────────────────────────────────────────
        CodeRabbit Usage — current billing period

        Organization  : Acme Corp
        Usage billing : active
        User          : Alice
        Your reviews  : 42
        Period resets : 2026-10-15
        ────────────────────────────────────────
        """

        let authOutput = """
        ────────────────────────────────────────
        CodeRabbit Auth

        User info
        Account      : alice_dev (alice@example.com)
        Provider     : GitHub
        Region       : US
        Organization : Acme Corp (1 available)
        ────────────────────────────────────────

        Review access
        Default      : Acme/Repo
        Plan         : Pro
        Seat         : assigned
        ────────────────────────────────────────
        """

        let snapshot = try CodeRabbitUsageParser.parse(
            usageText: usageOutput,
            authText: authOutput,
            now: now)

        #expect(snapshot.organization == "Acme Corp")
        #expect(snapshot.user == "Alice")
        #expect(snapshot.accountEmail == "alice@example.com")
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.reviewsCount == 42)
        #expect(snapshot.usageBilling == "active")
        #expect(snapshot.periodResetsRaw == "2026-10-15")

        let usage = snapshot.toUsageSnapshot(now: now)
        #expect(usage.identity?.accountEmail == "alice@example.com")
        #expect(usage.identity?.accountOrganization == "Acme Corp")
        #expect(usage.identity?.loginMethod == "Pro · 42 reviews")
    }

    @Test
    func `signed out output throws notLoggedIn`() {
        let output = "Please log in using `coderabbit auth login` to check your usage."

        #expect {
            try CodeRabbitUsageParser.parse(usageText: output)
        } throws: { error in
            guard case CodeRabbitUsageError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `empty or invalid output throws parseFailed`() {
        let output = "Some random error happened."

        #expect {
            try CodeRabbitUsageParser.parse(usageText: output)
        } throws: { error in
            guard case CodeRabbitUsageError.parseFailed = error else { return false }
            return true
        }
    }
}
