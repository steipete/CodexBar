import Foundation
import Testing
@testable import CodexBarCore

struct OllamaUsageParserTests {
    @Test
    func `parses cloud usage from settings HTML`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <h2 class=\"text-xl\">
            <span>Cloud Usage</span>
            <span class=\"text-xs\">free</span>
          </h2>
          <h2 id=\"header-email\">user@example.com</h2>
          <div>
            <span>Session usage</span>
            <span>0.1% used</span>
            <div class=\"local-time\" data-time=\"2026-01-30T18:00:00Z\">Resets in 3 hours</div>
          </div>
          <div>
            <span>Weekly usage</span>
            <span>0.7% used</span>
            <div class=\"local-time\" data-time=\"2026-02-02T00:00:00Z\">Resets in 2 days</div>
          </div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.planName == "free")
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.sessionUsedPercent == 0.1)
        #expect(snapshot.weeklyUsedPercent == 0.7)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedSession = formatter.date(from: "2026-01-30T18:00:00Z")
        let expectedWeekly = formatter.date(from: "2026-02-02T00:00:00Z")
        #expect(snapshot.sessionResetsAt == expectedSession)
        #expect(snapshot.weeklyResetsAt == expectedWeekly)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.loginMethod == "free")
        #expect(usage.identity?.accountEmail == "user@example.com")
    }

    @Test
    func `missing usage throws parse failed`() {
        let html = "<html><body>No usage here. login status unknown.</body></html>"

        #expect {
            try OllamaUsageParser.parse(html: html)
        } throws: { error in
            guard case let OllamaUsageError.parseFailed(message) = error else { return false }
            return message.contains("Missing Ollama usage data")
        }
    }

    @Test
    func `classified parse missing usage returns typed failure`() {
        let html = "<html><body>No usage here. login status unknown.</body></html>"
        let result = OllamaUsageParser.parseClassified(html: html)

        switch result {
        case .success:
            Issue.record("Expected classified parse failure for missing usage data")
        case let .failure(failure):
            #expect(failure == .missingUsageData)
        }
    }

    @Test
    func `signed out throws not logged in`() {
        let html = """
        <html>
          <body>
            <h1>Sign in to Ollama</h1>
            <form action="/auth/signin" method="post">
              <input type="email" name="email" />
              <input type="password" name="password" />
            </form>
          </body>
        </html>
        """

        #expect {
            try OllamaUsageParser.parse(html: html)
        } throws: { error in
            guard case OllamaUsageError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `classified parse signed out returns typed failure`() {
        let html = """
        <html>
          <body>
            <h1>Sign in to Ollama</h1>
            <form action="/auth/signin" method="post">
              <input type="email" name="email" />
              <input type="password" name="password" />
            </form>
          </body>
        </html>
        """

        let result = OllamaUsageParser.parseClassified(html: html)
        switch result {
        case .success:
            Issue.record("Expected classified parse failure for signed-out HTML")
        case let .failure(failure):
            #expect(failure == .notLoggedIn)
        }
    }

    @Test
    func `generic sign in text without auth markers throws parse failed`() {
        let html = """
        <html>
          <body>
            <h2>Usage Dashboard</h2>
            <p>If you have an account, you can sign in from the homepage.</p>
            <div>No usage rows rendered.</div>
          </body>
        </html>
        """

        #expect {
            try OllamaUsageParser.parse(html: html)
        } throws: { error in
            guard case let OllamaUsageError.parseFailed(message) = error else { return false }
            return message.contains("Missing Ollama usage data")
        }
    }

    @Test
    func `parses hourly usage as primary window`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <span>Hourly usage</span>
          <span>2.5% used</span>
          <div class=\"local-time\" data-time=\"2026-01-30T18:00:00Z\">Resets in 3 hours</div>
          <span>Weekly usage</span>
          <span>4.2% used</span>
          <div class=\"local-time\" data-time=\"2026-02-02T00:00:00Z\">Resets in 2 days</div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.sessionUsedPercent == 2.5)
        #expect(snapshot.weeklyUsedPercent == 4.2)
    }

    @Test
    func `parses usage when used is capitalized`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <span>Session usage</span>
          <span>1.2% Used</span>
          <div class=\"local-time\" data-time=\"2026-01-30T18:00:00Z\">Resets in 3 hours</div>
          <span>Weekly usage</span>
          <span>3.4% USED</span>
          <div class=\"local-time\" data-time=\"2026-02-02T00:00:00Z\">Resets in 2 days</div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.sessionUsedPercent == 1.2)
        #expect(snapshot.weeklyUsedPercent == 3.4)
    }
}
