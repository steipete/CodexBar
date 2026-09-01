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
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
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

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `weekly usage parser finds reset timestamp in long usage block`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let filler = String(repeating: "<span class=\"grid-cell\"></span>", count: 40)
        let html = """
        <div>
          <span>Session usage</span>
          <span>0.1% used</span>
          <span>Weekly usage</span>
          <span>0.7% used</span>
          \(filler)
          <div class=\"local-time\" data-time=\"2026-02-02T00:00:00Z\">Resets in 2 days</div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedWeekly = formatter.date(from: "2026-02-02T00:00:00Z")
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary?.resetsAt == expectedWeekly)
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

    @Test
    func `parses monthly dollar usage from new settings HTML`() throws {
        // 2026-08 改版后的真实页面结构：月度美元计量 + data-time 月度重置点。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <h2 class="text-xl font-medium flex items-center space-x-2">
            <span>Included usage</span>
            <span
              class="text-xs font-normal px-2 py-0.5 rounded-full bg-neutral-100 text-neutral-600 capitalize"
              >pro</span
            >
          </h2>
          <h2 id="header-email">user@example.com</h2>
          <div>
            <div class="flex justify-between mb-2">
              <span class="text-sm">Monthly usage</span>
              <span class="text-sm "
                >$7.50 of $60 used</span
              >
            </div>
            <div class="relative group" data-usage-meter>
              <div
                class="relative h-3 overflow-hidden rounded-full bg-neutral-200"
                data-usage-track
                aria-label="Monthly usage $7.50 of $60 used"
              >
                <div class="flex h-full overflow-hidden bg-neutral-950" style="width: 12.5%; ">
                </div>
              </div>
            </div>
            <div
              class="text-xs text-neutral-500 mt-1 local-time"
              data-time="2026-09-30T15:14:29Z"
            >
              Resets in 4 weeks.
            </div>
          </div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.planName == "pro")
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.monthlyUsedPercent == 12.5)
        #expect(snapshot.sessionUsedPercent == nil)
        #expect(snapshot.weeklyUsedPercent == nil)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedReset = formatter.date(from: "2026-09-30T15:14:29Z")
        #expect(snapshot.monthlyResetsAt == expectedReset)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.resetsAt == expectedReset)
        #expect(usage.secondary == nil)
        #expect(usage.identity?.loginMethod == "pro")
    }

    @Test
    func `monthly dollar usage handles thousands separators`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <span>Monthly usage</span>
          <span>$1,250 of $5,000 used</span>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.monthlyUsedPercent == 25)
    }

    @Test
    func `monthly dollar usage with zero limit falls back to meter width`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <span>Monthly usage</span>
          <span>$0 of $0 used</span>
          <div style="width: 25%; "></div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.monthlyUsedPercent == 25)
    }

    @Test
    func `legacy session page still maps weekly to secondary window`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>
          <span>Cloud Usage</span>
          <span>free</span>
          <span>Session usage</span>
          <span>0.1% used</span>
          <div class="local-time" data-time="2026-01-30T18:00:00Z">Resets in 3 hours</div>
        </div>
        """

        let snapshot = try OllamaUsageParser.parse(html: html, now: now)

        #expect(snapshot.monthlyUsedPercent == nil)
        #expect(snapshot.sessionUsedPercent == 0.1)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.secondary == nil)
    }
}
