import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenAIDashboardParserTests {
    @Test
    func `parses signed in email from client bootstrap HTML`() {
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
    func `parses code review remaining percent inline`() {
        let body = "Balance\nCode review 42% remaining\nCredits remaining 291"
        #expect(OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: body) == 42)
    }

    @Test
    func `parses code review remaining percent multiline`() {
        let body = "Balance\nCode review\n100% remaining\nWeekly usage limit\n0% remaining"
        #expect(OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: body) == 100)
    }

    @Test
    func `parses code review limit with reset`() {
        let body = """
        Balance
        Code review
        42% remaining
        Resets tomorrow at 2:15 PM
        """
        let limit = OpenAIDashboardParser.parseCodeReviewLimit(bodyText: body)
        #expect(abs((limit?.usedPercent ?? 0) - 58) < 0.001)
        #expect(limit?.resetDescription?.lowercased().contains("resets") == true)
    }

    @Test
    func `parses core review limit with reset`() {
        let body = """
        Balance
        Core review
        42% remaining
        Resets tomorrow at 2:15 PM
        """
        let limit = OpenAIDashboardParser.parseCodeReviewLimit(bodyText: body)
        #expect(abs((limit?.usedPercent ?? 0) - 58) < 0.001)
        #expect(limit?.resetDescription?.lowercased().contains("resets") == true)
    }

    @Test
    func `parses credits remaining`() {
        let body = "Balance\nCredits remaining 1,234.56\nUsage"
        let value = OpenAIDashboardParser.parseCreditsRemaining(bodyText: body)
        #expect(abs((value ?? 0) - 1234.56) < 0.001)
    }

    @Test
    func `parses rate limits`() {
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
    func `parses plan from client bootstrap`() {
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
    func `parses prolite plan from client bootstrap`() {
        let html = """
        <html>
        <body>
        <script type="application/json" id="client-bootstrap">
        {"session":{"user":{"email":"user@example.com"}},"planType":"prolite"}
        </script>
        </body>
        </html>
        """
        #expect(OpenAIDashboardParser.parsePlanFromHTML(html: html) == "Pro Lite")
    }

    @Test
    func `parses credit events from table rows`() {
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
    func `builds daily breakdown from events`() throws {
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
    func `decodes snapshot without usage breakdown field`() throws {
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

    @Test
    func `captured day key uses local timezone for iso timestamps`() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 60 * 60 * 3))
        let day = OpenAIDashboardParser.capturedDayKey(
            "2026-04-18T23:30:00Z",
            timeZone: timeZone)
        #expect(day == "2026-04-19")
    }

    @Test
    func `parses captured dashboard responses`() {
        let json = """
        [
          {
            "url": "https://chatgpt.com/backend-api/codex/usage",
            "json": {
              "rateLimit": {
                "primary_window": {
                  "remaining_percent": 72,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600
                },
                "secondary_window": {
                  "remaining_percent": 41,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 7200
                }
              },
              "codeReviewRateLimit": {
                "primary_window": {
                  "remaining_percent": 42,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 1800
                }
              },
              "creditDetails": {
                "balance": 2988.97,
                "unlimited": false
              }
            }
          },
          {
            "url": "https://chatgpt.com/backend-api/codex/credit-history",
            "json": {
              "data": [
                {
                  "date": "2026-04-18T00:00:00Z",
                  "product_surface": "cli",
                  "credit_amount": 397.205
                }
              ]
            }
          },
          {
            "url": "https://chatgpt.com/backend-api/codex/usage-breakdown",
            "json": {
              "data": [
                {
                  "date": "2026-04-18",
                  "product_surface_usage_values": {
                    "cli": 12,
                    "github_code_review": 5,
                    "unknown": 1
                  }
                }
              ]
            }
          }
        ]
        """

        let captured = OpenAIDashboardParser.parseCapturedDashboardData(
            responsesJSON: json,
            now: Date(timeIntervalSince1970: 1_776_500_000))

        #expect(abs((captured?.creditsRemaining ?? 0) - 2988.97) < 0.001)
        #expect(abs((captured?.primaryLimit?.usedPercent ?? 0) - 28) < 0.001)
        #expect(captured?.primaryLimit?.windowMinutes == 300)
        #expect(abs((captured?.secondaryLimit?.usedPercent ?? 0) - 59) < 0.001)
        #expect(captured?.secondaryLimit?.windowMinutes == 10080)
        #expect(abs((captured?.codeReviewLimit?.usedPercent ?? 0) - 58) < 0.001)
        #expect(captured?.creditEvents.count == 1)
        #expect(captured?.creditEvents.first?.service == "CLI")
        #expect(abs((captured?.creditEvents.first?.creditsUsed ?? 0) - 397.205) < 0.0001)
        #expect(captured?.usageBreakdown.count == 1)
        #expect(captured?.usageBreakdown.first?.services.first?.service == "CLI")
        #expect(abs((captured?.usageBreakdown.first?.totalCreditsUsed ?? 0) - 18) < 0.001)
        #expect(captured?.hasDashboardSignal == true)
    }

    @Test
    func `parses large captured response payloads`() throws {
        let filler = (0..<2000).map { index in
            [
                "junk": [
                    "id": index,
                    "label": "node-\(index)",
                ],
            ]
        }
        let payload: [String: Any] = [
            "nodes": filler,
            "tail": [
                "creditDetails": [
                    "balance": 42,
                    "unlimited": false,
                ],
            ],
        ]
        let response: [String: Any] = [
            "url": "https://chatgpt.com/backend-api/codex/usage",
            "json": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: [response], options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))

        let captured = OpenAIDashboardParser.parseCapturedDashboardData(responsesJSON: json)

        #expect(captured?.creditsRemaining == 42)
        #expect(captured?.hasDashboardSignal == true)
    }

    @Test
    func `weekly only dashboard usage projects into secondary slot`() {
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: 25,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            secondaryLimit: nil,
            creditsRemaining: nil,
            accountPlan: "pro",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let usage = snapshot.toUsageSnapshot(provider: .codex)

        #expect(usage?.primary == nil)
        #expect(usage?.secondary?.usedPercent == 25)
        #expect(usage?.secondary?.windowMinutes == 10080)
        #expect(usage?.identity?.providerID == .codex)
        #expect(usage?.identity?.accountEmail == "user@example.com")
    }

    @Test
    func `dashboard usage projection returns nil when all limits are absent`() {
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: nil,
            creditsRemaining: nil,
            accountPlan: "pro",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.toUsageSnapshot(provider: .codex) == nil)
    }
}
