---
summary: "WebKit usage in CodexBar: WebView hosts, cookie stores, and teardown guidance."
read_when:
  - Touching WebKit-backed login windows or offscreen scraping
  - Debugging WebKit teardown crashes (especially x86_64)
  - Changing WebKit window lifecycle behavior
---

# WebKit usage

CodexBar uses WebKit in two places:
- Visible login/purchase windows (e.g. Cursor login, credits purchase).
- Offscreen WebViews for OpenAI dashboard scraping.

## Teardown helper

Use `WebKitTeardown` whenever a `WKWebView` + `NSWindow` should be torn down or hidden.
It centralizes Intel-friendly cleanup:
- Stops loading and clears delegates.
- Delays teardown so WebKit can unwind callbacks.
- Keeps owners retained briefly on x86_64 to avoid autorelease crashes.

## When to use

- Any WebKit window that closes after a flow (login, purchase, etc.).
- Offscreen WebView hosts that hide/close after scraping.

## Notes

- For login flows that persist cookies manually, prefer `WKWebsiteDataStore.nonPersistent()`.
- Keep window `isReleasedWhenClosed = false` when teardown is deferred.
- Avoid closing WebViews directly; route cleanup through the helper.
