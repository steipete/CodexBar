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

    @MainActor
    func test_resetInvalidatesStaleInFlightCaptureAndScopesEndpointToSameOrigin() async throws {
        if Self.shouldSkipWebKitOnCI() { return }

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        _ = webView.loadHTMLString(Self.fetchFixtureHTML, baseURL: URL(string: "https://chatgpt.com/"))
        try await Self.waitUntil(webView) {
            try await $0.evaluateJavaScript("window.fixtureReady === true") as? Bool == true
        }
        _ = try await webView.evaluateJavaScript(openAISubscriptionCaptureScript)

        _ = try await webView.evaluateJavaScript("window.fetch('/backend-api/subscriptions'); true")
        _ = try await webView.evaluateJavaScript(openAISubscriptionResetScript)
        try await Task.sleep(for: .milliseconds(150))
        let staleMetadata = try await Self.readMetadata(from: webView)
        XCTAssertNil(staleMetadata)

        _ = try await webView.evaluateJavaScript("window.fetch('https://example.com/backend-api/subscriptions'); true")
        try await Task.sleep(for: .milliseconds(150))
        let crossOriginMetadata = try await Self.readMetadata(from: webView)
        XCTAssertNil(crossOriginMetadata)

        _ = try await webView.evaluateJavaScript("window.fetch('/backend-api/subscriptions'); true")
        try await Self.waitUntil(webView) { try await Self.readMetadata(from: $0) != nil }
        let capturedMetadata = try await Self.readMetadata(from: webView)
        let metadata = try XCTUnwrap(capturedMetadata)
        XCTAssertEqual(metadata["activeUntil"] as? String, "2026-08-20T14:30:07.123Z")
        XCTAssertEqual(metadata["willRenew"] as? Bool, true)
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
            if try await condition(webView) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for WebKit fixture")
    }

    private static func shouldSkipWebKitOnCI() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["GITHUB_ACTIONS"] == "true" || environment["CI"] == "true"
    }

    private static let fetchFixtureHTML = """
    <html><body><script>
      window.fetch = input => new Promise(resolve => {
        setTimeout(() => resolve(new Response(JSON.stringify({
          active_until: '2026-08-20T14:30:07.123Z',
          will_renew: true
        }), { headers: { 'Content-Type': 'application/json' } })), 75);
      });
      window.fixtureReady = true;
    </script></body></html>
    """
}
#endif
