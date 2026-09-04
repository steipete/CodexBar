import WebKit
import XCTest
@testable import CodexBarCore

#if os(macOS)
final class OpenAISubscriptionMetadataTests: XCTestCase {
    func test_mapsRenewingSubscriptionToRenewalDate() throws {
        let metadata = try XCTUnwrap(OpenAISubscriptionMetadata.parse(
            activeUntil: "2026-08-20T14:30:07Z",
            willRenew: true))

        XCTAssertNil(metadata.expiresAt)
        XCTAssertEqual(metadata.renewsAt, ISO8601DateFormatter().date(from: "2026-08-20T14:30:07Z"))
    }

    func test_mapsNonRenewingSubscriptionToExpirationDate() throws {
        let metadata = try XCTUnwrap(OpenAISubscriptionMetadata.parse(
            activeUntil: "2026-08-20T14:30:07Z",
            willRenew: false))

        XCTAssertEqual(metadata.expiresAt, ISO8601DateFormatter().date(from: "2026-08-20T14:30:07Z"))
        XCTAssertNil(metadata.renewsAt)
    }

    func test_parsesFractionalISO8601Date() throws {
        let raw = "2026-08-20T14:30:07.123Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata = try XCTUnwrap(OpenAISubscriptionMetadata.parse(activeUntil: raw, willRenew: true))

        XCTAssertEqual(metadata.renewsAt, formatter.date(from: raw))
    }

    func test_rejectsMissingOrMalformedMetadata() {
        XCTAssertNil(OpenAISubscriptionMetadata.parse(activeUntil: nil, willRenew: true))
        XCTAssertNil(OpenAISubscriptionMetadata.parse(activeUntil: "not a date", willRenew: true))
        XCTAssertNil(OpenAISubscriptionMetadata.parse(activeUntil: "2026-08-20T14:30:07Z", willRenew: nil))
    }

    func test_numericRenewalFlagsAreUnavailableRatherThanEmpty() {
        for flag in ["0", "1"] {
            let data = Data("{\"active_until\":null,\"will_renew\":\(flag)}".utf8)
            XCTAssertFalse(OpenAIDashboardFetcher.subscriptionMetadataResult(from: data).succeeded)
        }
        for flag in ["null", "false"] {
            let data = Data("{\"active_until\":null,\"will_renew\":\(flag)}".utf8)
            let result = OpenAIDashboardFetcher.subscriptionMetadataResult(from: data)
            XCTAssertTrue(result.succeeded)
            XCTAssertNil(result.metadata)
        }
    }

    @MainActor
    func test_productionCaptureIgnoresResetAndCrossOriginResponses() async throws {
        try await Self.withProductionWebView { webView in
            _ = try await webView.evaluateJavaScript("window.fetch('/backend-api/subscriptions'); true")
            _ = try await webView.evaluateJavaScript(openAISubscriptionResetScript)
            _ = try await webView
                .evaluateJavaScript("window.fixtureRequests[0].finish(200, window.fixturePayload); true")
            let staleMetadata = try await Self.readMetadata(from: webView)
            XCTAssertNil(staleMetadata)

            _ = try await webView
                .evaluateJavaScript("window.fetch('https://example.com/backend-api/subscriptions'); true")
            _ = try await webView
                .evaluateJavaScript("window.fixtureRequests[1].finish(200, window.fixturePayload); true")
            let crossOriginMetadata = try await Self.readMetadata(from: webView)
            XCTAssertNil(crossOriginMetadata)

            _ = try await webView.evaluateJavaScript("window.fetch('/backend-api/subscriptions'); true")
            _ = try await webView
                .evaluateJavaScript("window.fixtureRequests[2].finish(200, window.fixturePayload); true")
            try await Self.waitUntil(webView) { try await Self.readMetadata(from: $0) != nil }
            let metadata = try await Self.readMetadata(from: webView)
            XCTAssertEqual(metadata?["activeUntil"] as? String, "2026-08-20T14:30:07.123Z")
            XCTAssertEqual(metadata?["willRenew"] as? Bool, true)
        }
    }

    @MainActor
    func test_concurrentCapturePublishesStatusAndBodyFromOnlyTheLatestRequest() async throws {
        try await Self.withProductionWebView { webView in
            _ = try await webView.evaluateJavaScript("""
            window.fetch('/backend-api/subscriptions');
            window.fixtureRequests[0].headers(200);
            window.fetch('/backend-api/subscriptions');
            window.fixtureRequests[1].headers(403);
            window.fixtureRequests[1].body({active_until: null, will_renew: null}); true
            """)
            try await Self.waitUntil(webView) {
                let state = try await $0.evaluateJavaScript(openAISubscriptionReadScript) as? [String: Any]
                return state?["responseSettled"] as? Bool == true
            }
            _ = try await webView.evaluateJavaScript("window.fixtureRequests[0].body(window.fixturePayload); true")
            let state = try await webView.evaluateJavaScript(openAISubscriptionReadScript) as? [String: Any]
            XCTAssertEqual(state?["responseStatus"] as? Int, 403)
            let metadata = state?["metadata"] as? [String: Any]
            XCTAssertTrue(metadata?["activeUntil"] is NSNull)
            XCTAssertTrue(metadata?["willRenew"] is NSNull)
        }
    }

    @MainActor
    private static func withProductionWebView(_ body: (WKWebView) async throws -> Void) async throws {
        if self.shouldSkipWebKitOnCI() {
            throw XCTSkip("WebKit requires a GUI session")
        }
        let cache = OpenAIDashboardWebViewCache()
        defer { cache.clearAllForTesting() }
        cache.didCreateWebViewForTesting = { webView, _ in
            let controller = webView.configuration.userContentController
            let scripts = controller.userScripts.map {
                (source: $0.source, injectionTime: $0.injectionTime, isForMainFrameOnly: $0.isForMainFrameOnly)
            }
            XCTAssertTrue(scripts.contains {
                $0.source == openAISubscriptionCaptureScript && $0.injectionTime == .atDocumentStart
            })
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: Self.fetchFixtureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            for script in scripts {
                controller.addUserScript(WKUserScript(
                    source: script.source,
                    injectionTime: script.injectionTime,
                    forMainFrameOnly: script.isForMainFrameOnly))
            }
        }
        cache.prepareForTesting = { webView, _, _ in
            _ = webView.loadHTMLString(
                "<html><body>Subscription fixture</body></html>",
                baseURL: URL(string: "https://chatgpt.com/"))
            try await Self.waitUntil(webView) {
                try await $0.evaluateJavaScript("window.fixtureRequests !== undefined") as? Bool == true
            }
        }
        let lease = try await cache.acquire(
            websiteDataStore: .nonPersistent(), usageURL: URL(string: "about:blank")!, logger: nil)
        defer { lease.release() }
        try await body(lease.webView)
    }

    @MainActor
    private static func readMetadata(from webView: WKWebView) async throws -> [String: Any]? {
        let any = try await webView.evaluateJavaScript(openAISubscriptionReadScript)
        return (any as? [String: Any])?["metadata"] as? [String: Any]
    }

    @MainActor
    private static func waitUntil(
        _ webView: WKWebView,
        condition: (WKWebView) async throws -> Bool) async throws
    {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try await condition(webView) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for WebKit fixture")
    }

    private static func shouldSkipWebKitOnCI() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["GITHUB_ACTIONS"] == "true" || environment["CI"] == "true"
    }

    private static let fetchFixtureScript = """
    window.fixtureRequests = [];
    window.fixturePayload = {active_until: '2026-08-20T14:30:07.123Z', will_renew: true};
    window.fetch = input => new Promise(resolve => {
      let resolveBody;
      const body = new Promise(done => { resolveBody = done; });
      const request = {
        headers: status => resolve({status, clone: () => ({json: () => body})}),
        body: payload => resolveBody(payload),
        finish: (status, payload) => { request.headers(status); request.body(payload); }
      };
      window.fixtureRequests.push(request);
    });
    """
}
#endif
