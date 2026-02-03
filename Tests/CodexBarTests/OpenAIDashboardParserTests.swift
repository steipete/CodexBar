import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct OpenAIDashboardParserTests {
    @Test
    func parsesSignedInEmailFromClientBootstrapHTML() {
        let html = """
        <html>
        <head></head>
        <body>
        <script type="application/json" id="client-bootstrap">
        {"authStatus":"logged_in","session":{"user":{"email":"studpete@gmail.com"}}}
        </script>
        </body>
        </html>
        """
        #expect(OpenAIDashboardParser.parseSignedInEmailFromClientBootstrap(html: html) == "studpete@gmail.com")
        #expect(OpenAIDashboardParser.parseAuthStatusFromClientBootstrap(html: html) == "logged_in")
    }

    @Test
    func parsesCodeReviewRemainingPercent_inline() {
        let body = "Balance\nCode review 42% remaining\nCredits remaining 291"
        #expect(OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: body) == 42)
    }

    @Test
    func parsesCodeReviewRemainingPercent_multiline() {
        let body = "Balance\nCode review\n100% remaining\nWeekly usage limit\n0% remaining"
        #expect(OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: body) == 100)
    }

    @Test
    func parsesCreditsRemaining() {
        let body = "Balance\nCredits remaining 1,234.56\nUsage"
        let value = OpenAIDashboardParser.parseCreditsRemaining(bodyText: body)
        #expect(abs((value ?? 0) - 1234.56) < 0.001)
    }

    @Test
    func parsesRateLimits() {
        let body = """
        Usage limits
        5h limit
        72% remaining
        Resets today at 2:15 PM
        Weekly limit
        41% remaining
        Resets Fri at 9:00 AM
        """
        let limits = OpenAIDashboardParser.parseRateLimits(bodyText: body)
        #expect(abs((limits.primary?.usedPercent ?? 0) - 28) < 0.001)
        #expect(limits.primary?.windowMinutes == 300)
        #expect(limits.primary?.resetDescription?.lowercased().contains("resets") == true)
        #expect(abs((limits.secondary?.usedPercent ?? 0) - 59) < 0.001)
        #expect(limits.secondary?.windowMinutes == 10080)
    }

    @Test
    func parsesPlanFromClientBootstrap() {
        let html = """
        <html>
        <body>
        <script type="application/json" id="client-bootstrap">
        {"session":{"user":{"email":"user@example.com"}},"planType":"plus"}
        </script>
        </body>
        </html>
        """
        #expect(OpenAIDashboardParser.parsePlanFromHTML(html: html) == "Plus")
    }

    @Test
    func parsesCreditEventsFromTableRows() {
        let rows: [[String]] = [
            ["Dec 18, 2025", "CLI", "397.205 credits"],
            ["Dec 17, 2025", "GitHub Code Review", "506.235 credits"],
        ]
        let events = OpenAIDashboardParser.parseCreditEvents(rows: rows)
        #expect(events.count == 2)
        #expect(events.first?.service == "CLI")
        #expect(abs((events.first?.creditsUsed ?? 0) - 397.205) < 0.0001)
        #expect(events.last?.service == "GitHub Code Review")
        #expect(abs((events.last?.creditsUsed ?? 0) - 506.235) < 0.0001)
    }

    @Test
    func buildsDailyBreakdownFromEvents() throws {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)

        components.year = 2025
        components.month = 12
        components.day = 18
        let dec18 = try #require(components.date)

        components.day = 17
        let dec17 = try #require(components.date)

        let events = [
            CreditEvent(date: dec18, service: "CLI", creditsUsed: 10),
            CreditEvent(date: dec18, service: "CLI", creditsUsed: 5),
            CreditEvent(date: dec18, service: "GitHub Code Review", creditsUsed: 2),
            CreditEvent(date: dec17, service: "CLI", creditsUsed: 1),
        ]

        let breakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: events, maxDays: 30)
        #expect(breakdown.count == 2)
        #expect(breakdown.first?.services.first?.service == "CLI")
        #expect(abs((breakdown.first?.services.first?.creditsUsed ?? 0) - 15) < 0.0001)
    }

    @Test
    func decodesSnapshotWithoutUsageBreakdownField() throws {
        let json = """
        {
          "signedInEmail": "user@example.com",
          "codeReviewRemainingPercent": 42,
          "creditEvents": [],
          "dailyBreakdown": [],
          "updatedAt": "2025-12-18T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(OpenAIDashboardSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.usageBreakdown.isEmpty)
    }
}
