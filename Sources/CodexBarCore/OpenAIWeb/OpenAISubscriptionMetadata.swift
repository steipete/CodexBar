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
  window.__codexbarSubscriptionResponseStatus = null;
  window.__codexbarSubscriptionResponseSettled = false;
  window.__codexbarSubscriptionMetadata = null;
  window.__codexbarSubscriptionMetadataParseState = null;
  const originalFetch = window.fetch.bind(window);
  let latestRequest = 0;
  window.fetch = async (...args) => {
    const generation = window.__codexbarSubscriptionCaptureGeneration;
    let request = null;
    try {
      const input = args[0];
      const requestURL = new URL(String(input && input.url ? input.url : input), window.location.href);
      if (requestURL.origin === window.location.origin && requestURL.pathname === '/backend-api/subscriptions') {
        request = ++latestRequest;
        window.__codexbarSubscriptionResponseStatus = null;
        window.__codexbarSubscriptionResponseSettled = false;
        window.__codexbarSubscriptionMetadata = null;
        window.__codexbarSubscriptionMetadataParseState = null;
      }
    } catch (_) {}
    const response = await originalFetch(...args);
    if (request !== null) {
      const publish = (metadata, valid) => {
        if (window.__codexbarSubscriptionCaptureGeneration !== generation || request !== latestRequest) return;
        window.__codexbarSubscriptionResponseStatus = response.status;
        window.__codexbarSubscriptionMetadata = metadata;
        window.__codexbarSubscriptionMetadataParseState = valid ? 'valid' : 'invalid';
        window.__codexbarSubscriptionResponseSettled = true;
      };
      try {
        response.clone().json().then(payload => {
          const hasActiveUntil = payload &&
            (Object.prototype.hasOwnProperty.call(payload, 'active_until') ||
             Object.prototype.hasOwnProperty.call(payload, 'activeUntil'));
          const hasWillRenew = payload &&
            (Object.prototype.hasOwnProperty.call(payload, 'will_renew') ||
             Object.prototype.hasOwnProperty.call(payload, 'willRenew'));
          const activeUntil = Object.prototype.hasOwnProperty.call(payload || {}, 'active_until')
            ? payload.active_until : payload?.activeUntil;
          const willRenew = Object.prototype.hasOwnProperty.call(payload || {}, 'will_renew')
            ? payload.will_renew : payload?.willRenew;
          const valid = hasActiveUntil && hasWillRenew &&
            (activeUntil === null || typeof activeUntil === 'string') &&
            (willRenew === null || typeof willRenew === 'boolean');
          publish(valid ? { activeUntil, willRenew } : null, valid);
        }).catch(() => publish(null, false));
      } catch (_) { publish(null, false); }
    }
    return response;
  };
})();
"""

let openAISubscriptionResetScript = """
(() => {
  const generation = Number(window.__codexbarSubscriptionCaptureGeneration || 0) + 1;
  window.__codexbarSubscriptionCaptureGeneration = generation;
  window.__codexbarSubscriptionResponseStatus = null;
  window.__codexbarSubscriptionResponseSettled = false;
  window.__codexbarSubscriptionMetadata = null;
  window.__codexbarSubscriptionMetadataParseState = null;
  return generation;
})();
"""

let openAISubscriptionReadScript = """
(() => ({
  isBillingRoute: String(window.location.hash || '').toLowerCase().includes('settings/billing'),
  responseStatus: window.__codexbarSubscriptionResponseStatus,
  responseSettled: window.__codexbarSubscriptionResponseSettled,
  metadataParseState: window.__codexbarSubscriptionMetadataParseState,
  metadata: window.__codexbarSubscriptionMetadata || null
}))();
"""

/// Opens ChatGPT's billing settings so its frontend performs the authenticated
/// subscription request captured by `openAISubscriptionCaptureScript`.
@MainActor
enum OpenAISubscription {
    private static let billingURL = URL(string: "https://chatgpt.com/#settings/Billing")!

    static func fetch(
        _ webView: WKWebView,
        deadline: Date,
        logger: @escaping (String) -> Void) async throws -> OpenAISubscriptionFetchResult
    {
        guard Date() < deadline else { return .unavailable }
        try Task.checkCancellation()

        guard try await self.evaluate(openAISubscriptionResetScript, in: webView, deadline: deadline) != nil else {
            logger("subscription metadata reset unavailable")
            return .unavailable
        }
        try Task.checkCancellation()
        guard Date() < deadline else { return .unavailable }

        _ = webView.load(OpenAIDashboardFetcher.usageURLRequest(url: self.billingURL))
        let billingDeadline = min(deadline, Date().addingTimeInterval(8))

        while Date() < billingDeadline {
            try await Task.sleep(for: .seconds(min(0.4, max(0, billingDeadline.timeIntervalSinceNow))))
            try Task.checkCancellation()
            guard Date() < billingDeadline else { break }
            let any = try await Self.evaluate(openAISubscriptionReadScript, in: webView, deadline: billingDeadline)
            try Task.checkCancellation()
            guard Date() < billingDeadline else { break }
            guard let any,
                  let result = any as? [String: Any],
                  (result["isBillingRoute"] as? Bool) == true,
                  (result["responseSettled"] as? Bool) == true
            else { continue }

            guard let status = result["responseStatus"] as? Int, (200..<300).contains(status) else {
                logger("subscription metadata unavailable")
                return .unavailable
            }

            guard (result["metadataParseState"] as? String) == "valid" else {
                logger("subscription metadata response invalid")
                return .unavailable
            }

            let raw = result["metadata"] as? [String: Any]
            let parsed = OpenAISubscriptionMetadata.parseResult(
                activeUntil: raw?["activeUntil"] as? String,
                willRenew: raw?["willRenew"] as? Bool,
                fieldsPresent: raw != nil)

            if case let .success(metadata) = parsed, let metadata {
                logger(
                    "subscription metadata found " +
                        "renewal=\(metadata.renewsAt == nil ? "0" : "1") " +
                        "expiration=\(metadata.expiresAt == nil ? "0" : "1")")
            } else if case .success = parsed {
                logger("subscription metadata response empty")
            } else {
                logger("subscription metadata response invalid")
            }
            return parsed
        }

        logger("subscription metadata unavailable")
        return .unavailable
    }

    private static func evaluate(_ script: String, in webView: WKWebView, deadline: Date) async throws -> Any? {
        let data: Data? = try await OpenAIDashboardBrowserCookieImporter.runBoundedValueCallback(
            deadline: deadline)
        { completion in
            webView.evaluateJavaScript(script) { result, error in
                guard error == nil, let result else { return completion(nil) }
                completion(try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed))
            }
        }
        try Task.checkCancellation()
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
}
#endif
