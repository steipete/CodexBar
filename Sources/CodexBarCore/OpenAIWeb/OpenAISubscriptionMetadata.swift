#if os(macOS)
import Foundation
import WebKit

/// Captures only the renewal fields from ChatGPT's own subscription request.
/// The response remains in the authenticated page; no cookies, IDs, or raw payloads
/// are passed back to CodexBar.
let openAISubscriptionCaptureScript = """
(() => {
  if (window.__codexbarSubscriptionCaptureInstalled) return;
  window.__codexbarSubscriptionCaptureInstalled = true;
  window.__codexbarSubscriptionCaptureGeneration = 0;
  const originalFetch = window.fetch.bind(window);
  window.fetch = async (...args) => {
    const generation = window.__codexbarSubscriptionCaptureGeneration;
    const response = await originalFetch(...args);
    try {
      const input = args[0];
      const rawURL = input && input.url ? input.url : input;
      const requestURL = new URL(String(rawURL), window.location.href);
      if (requestURL.origin === window.location.origin &&
          requestURL.pathname === '/backend-api/subscriptions') {
        response.clone().json().then(payload => {
          if (window.__codexbarSubscriptionCaptureGeneration !== generation) return;
          window.__codexbarSubscriptionMetadata = {
            activeUntil: typeof payload?.active_until === 'string' ? payload.active_until : null,
            willRenew: typeof payload?.will_renew === 'boolean' ? payload.will_renew : null
          };
        }).catch(() => {});
      }
    } catch (_) {}
    return response;
  };
})();
"""

let openAISubscriptionResetScript = """
(() => {
  const generation = Number(window.__codexbarSubscriptionCaptureGeneration || 0) + 1;
  window.__codexbarSubscriptionCaptureGeneration = generation;
  window.__codexbarSubscriptionMetadata = null;
  return generation;
})();
"""

let openAISubscriptionReadScript = """
(() => ({
  isBillingRoute: String(window.location.hash || '').toLowerCase().includes('settings/billing'),
  metadata: window.__codexbarSubscriptionMetadata || null
}))();
"""

struct OpenAISubscriptionMetadata: Equatable {
    let expiresAt: Date?
    let renewsAt: Date?

    static func parse(activeUntil: String?, willRenew: Bool?) -> Self? {
        guard let activeUntil,
              let willRenew,
              let date = self.parseISO8601(activeUntil)
        else { return nil }

        return willRenew
            ? Self(expiresAt: nil, renewsAt: date)
            : Self(expiresAt: date, renewsAt: nil)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Opens ChatGPT's billing settings so its frontend performs the authenticated
/// subscription request captured by `openAISubscriptionCaptureScript`.
@MainActor
enum OpenAISubscription {
    private static let billingURL = URL(string: "https://chatgpt.com/#settings/Billing")!
    private static let usageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!

    static func fetch(
        _ webView: WKWebView,
        deadline: Date,
        logger: @escaping (String) -> Void) async throws -> OpenAISubscriptionMetadata?
    {
        guard Date() < deadline else { return nil }
        try Task.checkCancellation()

        guard await (try? webView.evaluateJavaScript(openAISubscriptionResetScript)) != nil else {
            logger("subscription metadata reset unavailable")
            return nil
        }
        try Task.checkCancellation()

        _ = webView.load(OpenAIDashboardFetcher.usageURLRequest(url: self.billingURL))
        let billingDeadline = min(deadline, Date().addingTimeInterval(8))
        defer { _ = webView.load(OpenAIDashboardFetcher.usageURLRequest(url: self.usageURL)) }

        while Date() < billingDeadline {
            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
            guard let any = try? await webView.evaluateJavaScript(openAISubscriptionReadScript),
                  let result = any as? [String: Any],
                  (result["isBillingRoute"] as? Bool) == true,
                  let raw = result["metadata"] as? [String: Any],
                  let metadata = OpenAISubscriptionMetadata.parse(
                      activeUntil: raw["activeUntil"] as? String,
                      willRenew: raw["willRenew"] as? Bool)
            else { continue }

            logger("subscription metadata found")
            return metadata
        }

        logger("subscription metadata unavailable")
        return nil
    }
}
#endif
