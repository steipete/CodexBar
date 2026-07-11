---
summary: "Cursor provider data sources: browser cookies or stored session; usage + billing via cursor.com APIs."
read_when:
  - Debugging Cursor usage parsing
  - Updating Cursor cookie import or session storage
  - Adjusting Cursor provider UI/menu behavior
---

# Cursor provider

Cursor is web-only. Usage is fetched via browser cookies or a stored WebKit session.

## Data sources + fallback order

1) **Cached cookie header** (preferred)
   - Stored after successful browser import.
   - Keychain cache: `com.steipete.codexbar.cache` (account `cookie.cursor`).

2) **Browser cookie import**
   - Cookie order from provider metadata (default: Safari → Chrome → Firefox).
   - Domain filters: `cursor.com`, `cursor.sh`.
   - Cookie names required (any one counts):
     - `WorkosCursorSessionToken`
     - `__Secure-next-auth.session-token`
     - `next-auth.session-token`

3) **Stored session cookies** (fallback)
   - Captured by the "Add Account" WebKit login flow.
   - Login teardown uses `WebKitTeardown` to avoid Intel WebKit crashes.
   - Stored at: `~/Library/Application Support/CodexBar/cursor-session.json`.

Manual option:
- Preferences → Providers → Cursor → Cookie source → Manual.
- Paste the `Cookie:` header from a cursor.com request.

## API endpoints
- `GET https://cursor.com/api/usage-summary`
  - Plan usage (included), on-demand usage, billing cycle window.
- `GET https://cursor.com/api/auth/me`
  - User email + name.
- `GET https://cursor.com/api/usage?user=ID`
  - Legacy request-based plan usage (request counts + limits).
- `POST https://cursor.com/api/dashboard/get-filtered-usage-events`
  - Cursor usage-event diagnostics for the billing-cycle and rolling 30-day menu/widget views.
  - Uses session cookies plus Cursor `Origin` and `Referer` headers. Requests are paged at 200 rows with a 20-page
    cap and a single 15-second deadline.
  - Diagnostics are all-or-nothing: the first non-nil total is authoritative, later omitted totals retain it, and a
    conflict, error, timeout, over-cap total, or capped incomplete result omits request diagnostics without affecting
    the independent quota shown above.

## Cookie file paths
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

## Snapshot mapping
- Primary: plan usage percent (included plan).
- Secondary: on-demand usage percent (individual usage).
- Provider cost: on-demand usage USD (limit when known).
- Legacy Cursor event rows render as one `Req 1` request. The API's optional `requestsCosts` stays a separate weighted
  diagnostic value, never a substitute for a row count or the legacy quota. When present, it appears only as an
  explicit `Request cost: N` detail alongside the local model-cost estimate.
- Cursor range selection defaults to `Cycle` and can switch to `30d`; it changes the event/token diagnostic surface
  only, not Cursor's primary plan quota. If the API omits a billing-cycle start, the diagnostic surface falls back to
  the complete `30d` range instead of hiding the available data.
- Cost estimates are local diagnostics, not Cursor billing. GPT total-only or partial rows use a conservative
  one-sided lower bound. `gpt-5.5-extra-high` resolves to the `gpt-5.5` price key while retaining effort metadata.
  Pricing was checked 2026-07-11 against [OpenAI GPT-5.5](https://openai.com/index/introducing-gpt-5-5/),
  [Cursor Composer 2.5](https://cursor.com/changelog/composer-2-5), and
  [Anthropic Claude Fable 5](https://www.anthropic.com/claude/fable).
- Reset: billing cycle end date.

## Key files
- `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
- `Sources/CodexBar/CursorLoginRunner.swift` (login flow)
