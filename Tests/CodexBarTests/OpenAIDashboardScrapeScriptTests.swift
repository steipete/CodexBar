#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct OpenAIDashboardScrapeScriptTests {
    @Test
    func `usage breakdown scraper ignores neighboring client charts`() async throws {
        if Self.shouldSkipOnCI() { return }

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        _ = webView.loadHTMLString(Self.multiChartHTML, baseURL: nil)
        try await Self.waitForFixture(webView)

        let any = try await webView.evaluateJavaScript(openAIDashboardScrapeScript)
        let dict = try #require(any as? [String: Any])
        let debug = dict["usageBreakdownDebug"] as? String
        let raw = try #require(dict["usageBreakdownJSON"] as? String, "debug: \(debug ?? "nil")")
        let decoded = try JSONDecoder().decode([OpenAIDashboardDailyBreakdown].self, from: Data(raw.utf8))

        #expect(decoded.count == 1)
        #expect(decoded.first?.day == "2026-05-01")
        #expect(decoded.first?.totalCreditsUsed == 30)
        #expect((decoded.first?.services.map(\.service) ?? []) == ["Desktop", "CLI"])
    }

    @Test
    func `usage breakdown scraper reports wrong chart instead of accepting it`() async throws {
        if Self.shouldSkipOnCI() { return }

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        _ = webView.loadHTMLString(Self.clientOnlyChartHTML, baseURL: nil)
        try await Self.waitForFixture(webView, elementID: "client-chart")

        let any = try await webView.evaluateJavaScript(openAIDashboardScrapeScript)
        let dict = try #require(any as? [String: Any])

        #expect((dict["usageBreakdownJSON"] as? String) == nil)
        #expect((dict["usageBreakdownError"] as? String)?.contains("Threads and turns by client") == true)
    }

    @Test
    func `usage breakdown scraper rejects non english chart titles`() async throws {
        if Self.shouldSkipOnCI() { return }

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        _ = webView.loadHTMLString(Self.localizedUsageChartHTML, baseURL: nil)
        try await Self.waitForFixture(webView)

        let any = try await webView.evaluateJavaScript(openAIDashboardScrapeScript)
        let dict = try #require(any as? [String: Any])

        #expect((dict["usageBreakdownJSON"] as? String) == nil)
        #expect(
            (dict["usageBreakdownError"] as? String)?
                .contains("No English usage breakdown chart title found") == true)
    }

    private static func shouldSkipOnCI() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true"
    }

    private static func waitForFixture(_ webView: WKWebView, elementID: String = "usage-chart") async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let loaded = try? await webView.evaluateJavaScript(
                "document.getElementById('\(elementID)') !== null") as? Bool
            if loaded == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static let multiChartHTML = """
    <html>
    <body>
      <section>
        <h2>Usage breakdown</h2>
        <div>
          <h3>Personal usage</h3>
        </div>
        <span>Daily threads by client</span>
        <svg class="recharts-surface">
          <g class="recharts-bar-rectangle">
            <path id="usage-chart" class="recharts-rectangle" d="M0 0H10V10Z"></path>
          </g>
        </svg>
      </section>
      <section>
        <h2>Product activity</h2>
        <button type="button">1,000 threads</button>
        <button type="button">2,000 turns</button>
        <span>Daily threads by client</span>
        <svg class="recharts-surface">
          <g class="recharts-bar-rectangle">
            <path id="client-chart" class="recharts-rectangle" d="M0 0H10V10Z"></path>
          </g>
        </svg>
      </section>
      <section>
        <h2>Tokens by model</h2>
        <svg class="recharts-surface">
          <g class="recharts-bar-rectangle">
            <path id="model-chart" class="recharts-rectangle" d="M0 0H10V10Z"></path>
          </g>
        </svg>
      </section>
      <script>
        document.getElementById('client-chart')['__reactProps$test'] = {
          dataKey: 'values',
          payload: {
            day: '2026-05-01',
            values: { cli: 1000, desktop: 2000 }
          }
        };
        document.getElementById('usage-chart')['__reactProps$test'] = {
          dataKey: 'values',
          payload: {
            day: '2026-05-01',
            values: { cli: 10, desktop: 20 }
          }
        };
        document.getElementById('model-chart')['__reactProps$test'] = {
          dataKey: 'values',
          payload: {
            day: '2026-05-01',
            values: { cli: 1000, desktop: 2000, vscode: 3000 }
          }
        };
      </script>
    </body>
    </html>
    """

    private static let clientOnlyChartHTML = """
    <html>
    <body>
      <section>
        <h2>Threads and turns by client</h2>
        <svg class="recharts-surface">
          <g class="recharts-bar-rectangle">
            <path id="client-chart" class="recharts-rectangle" d="M0 0H10V10Z"></path>
          </g>
        </svg>
      </section>
      <script>
        document.getElementById('client-chart')['__reactProps$test'] = {
          dataKey: 'values',
          payload: {
            day: '2026-05-01',
            values: { cli: 1000, desktop: 2000 }
          }
        };
      </script>
    </body>
    </html>
    """

    private static let localizedUsageChartHTML = """
    <html>
    <body>
      <section>
        <h2>Desglose de uso</h2>
        <svg class="recharts-surface">
          <g class="recharts-bar-rectangle">
            <path id="usage-chart" class="recharts-rectangle" d="M0 0H10V10Z"></path>
          </g>
        </svg>
      </section>
      <script>
        document.getElementById('usage-chart')['__reactProps$test'] = {
          dataKey: 'values',
          payload: {
            day: '2026-05-01',
            values: { cli: 10, desktop: 20 }
          }
        };
      </script>
    </body>
    </html>
    """
}
#endif
