---
summary: "ZoomMate provider auth, credits endpoint, history/pacing, and status page."
read_when:
  - Adding or modifying the ZoomMate provider
  - Debugging ZoomMate token import or usage parsing
  - Explaining ZoomMate setup
---

# ZoomMate Provider

The ZoomMate provider tracks credit usage against a budget cap from
[zoommate.zoom.us](https://zoommate.zoom.us). ZoomMate is a credits-based quota — there is no
session/weekly rate window, just a single primary "Credits" window.

CodexBar's ZoomMate branding uses Zoom's official core palette: Bloom (`#0B5CFF`) as the primary
color, with Dawn (`#B4D0F8`) and Midnight (`#00053D`) as supporting colors. Provenance:
[Zoom Brand Center, Visual identity — Color](https://brand.zoom.com/document/1#/visual-identity/color),
retrieved 2026-07-18 (page last modified 2025-08-28).

## Setup

### Automatic (recommended, Chrome only)

1. Sign in to ZoomMate in Chrome.
2. Enable **ZoomMate** in **Settings → Providers**. **Cookie source** defaults to **Auto**.

CodexBar imports your ZoomMate/Zoom session cookies from Chrome's cookie jar (covering
`zoommate.zoom.us`, `ai.zoom.us`, and the parent `zoom.us` domain, where Zoom's SSO session cookies
actually live) and exchanges them for a short-lived bearer token via the same
cookie-to-token bootstrap endpoint ZoomMate's own web app uses internally
(`GET https://ai.zoom.us/ai-computer/api/v1/login/?continue=...`) — no manual paste required. This
automatic path intentionally tries Chrome only to avoid surprise prompts from other browser stores;
other browsers must use manual capture.

Because the bearer token is minted from your (much longer-lived) session cookies, this keeps working
as long as you stay signed in to ZoomMate in Chrome. A minted token is reused from an in-memory cache
across refreshes until it nears expiry, then re-minted from the same cookies — no re-paste required.
If the Chrome session cookie is missing, CodexBar reports `noSession`; if Zoom rejects an existing
session, CodexBar reports `invalidCredentials`.

Chrome's cookie decryption key lives in the macOS Keychain, so CodexBar only reads Chrome's cookie
store during user-initiated refreshes (a menu or Settings refresh, or `codexbar cookie`). Once a
fresh import validates — the cookie-to-token mint succeeds — the validated cookie header is saved to
CodexBar's shared Keychain cookie cache (`com.steipete.codexbar.cache`, account `cookie.zoommate`,
same as other cookie providers) and reused before re-importing from Chrome. Background refreshes and
the bundled `codexbar` CLI run entirely from that cached header, so they never touch Chrome's cookie
store or trigger a Keychain prompt. If Zoom rejects the cached session, CodexBar drops it and retries
one fresh Chrome import (user-initiated contexts only; background refreshes report `noSession` until
the next user refresh).

### Manual

Set **Cookie source** to **Manual** in the ZoomMate provider settings, then paste a full `curl`
command captured from DevTools:

1. Open [zoommate.zoom.us](https://zoommate.zoom.us) and sign in.
2. Navigate to the AI credit usage page (Settings → AI credit usage, or equivalent).
3. Open Developer Tools → Network tab.
4. Reload the page and find the `credits/status` request
   (`GET https://ai.zoom.us/ai-computer/api/v1/credits/status`).
5. Right-click → Copy → Copy as cURL.
6. Paste the full `curl` command into the **ZoomMate capture** field in CodexBar settings.

Unlike some other manual-paste providers, the forwarded header allowlist for ZoomMate **includes
`Authorization`** — that's the required credential (see "Common errors" below). `Cookie` and
selected browser headers may also be forwarded, but `Origin` and `Referer` are always replaced with
the fixed `https://zoommate.zoom.us` value. Captures are accepted only for the HTTPS
`/ai-computer/api/v1/credits/status` endpoint on `ai.zoom.us` or `zoommate.zoom.us` — DevTools may
show the request on either host, since both currently serve the same first-party API.

## Token expiry (~hourly)

The ZoomMate bearer token itself is short-lived — typically about an hour. Session cookies live far
longer, so:

- **Automatic mode**: no action needed as long as you stay signed in to ZoomMate in Chrome;
  CodexBar mints a bearer token from your session cookies and reuses it (in memory) until it nears
  expiry, then re-mints automatically.
- **Manual mode**: re-capture and re-paste a fresh `curl` command when the pasted token expires
  (surfaced as `invalidCredentials` — see below). This is expected behavior, not a bug — switching
  to Automatic mode avoids it entirely.

## Auth & privacy

Automatic mode uses the same first-party ZoomMate web-client flow a signed-in browser uses:
CodexBar imports Zoom session cookies from the local Chrome cookie jar, sends those cookies only
to Zoom's `ai.zoom.us` login bootstrap endpoint, receives a short-lived bearer token, and then uses
that bearer token for the `credits/status` and `credits/history` requests.

The minted bearer token is never persisted — it is held only in a process-lifetime in-memory cache.
The validated cookie header (and only the header — never the bearer) is persisted to CodexBar's
existing shared Keychain cookie cache after a successful mint, the same cache and lifecycle other
cookie providers (Claude web, Perplexity, OpenCode, …) already use, so background refreshes and the
bundled CLI can reuse the session without rereading Chrome. ZoomMate logs intentionally omit
cookies, bearer tokens, `nak` values, and raw response bodies. The
cookie read spans the parent `zoom.us` domain because Zoom's SSO session cookies are parent-scoped,
but the imported set is then narrowed to only cookies a browser would actually attach to
`ai.zoom.us` / `zoommate.zoom.us` (RFC 6265 domain-matching), dropping cookies host-scoped to
unrelated `*.zoom.us` siblings that these endpoints never receive.

All authentication and credit requests use fixed HTTPS URLs on the two first-party API hosts:
`ai.zoom.us` is tried first, falling back to `zoommate.zoom.us` on non-auth failures. The hosts
currently serve the same `/ai-computer/` API interchangeably and either may retire in the future, so
the provider works with both; auth rejections (401/403) never trigger the fallback since the host
answered and the session is the problem. `zoommate.zoom.us` additionally provides the product UI and
the fixed web-client `continue`, `Origin`, and `Referer` values. The parent `zoom.us` scope is used
only to discover parent-scoped SSO cookies; it does not authorize requests to arbitrary Zoom
subdomains. ZoomMate does not currently expose a
documented public API, so this provider depends on the product's first-party web-client endpoints.

This cookie-to-bearer shape follows an existing CodexBar precedent in the Factory provider's WorkOS
cookie exchange. The minted bearer is cached in memory (keyed by a SHA-256 of the cookie session)
and reused until it nears its JWT `exp`; a token whose expiry can't be read is never cached, and a
`401/403` from a downstream request evicts the cached token so the next refresh mints fresh.

## Data Source

CodexBar sends up to a few GET requests per refresh:

```text
GET https://ai.zoom.us/ai-computer/api/v1/credits/status
GET https://ai.zoom.us/ai-computer/api/v1/credits/history?app_id=demo_app&limit=50&page=<n>&sort_by=time&sort_order=desc&start_time=<ISO8601>&end_time=<ISO8601>
```

(Each request retries once on `zoommate.zoom.us` with the same path if `ai.zoom.us` fails with a
non-auth error — see "Auth & privacy" above.)

The `credits/status` response's `data.credit_status` object is decoded into a
`ZoomMateCreditStatus` struct. The `credits/history` request is paginated (looping on `page` until
`page * limit + records.length` reaches the response's flat `data.total`, or a page's records are
entirely older than the requested `start_time`) to cover the last 30 days; real accounts have
modest history (tens of records total), so this is normally 1–2 requests. `app_id` is sent as a
fixed placeholder matching ZoomMate's own web UI — it does not scope the result set to a particular
integration. A failed `credits/history` fetch is non-fatal: it never blocks the primary
`credits/status` snapshot, it just means the history dashboard (below) is omitted for that refresh.

### Fields mapped to the Credits window

| Source field | CodexBar mapping |
|---|---|
| `used_credit` / `budget_cap` | Primary window `usedPercent` (clamped 0–100) |
| `cycle_end_date` | Primary window reset time (epoch ms) |
| `is_unlimited` / `budget_cap <= 0` | `usedPercent` forced to 0, reset countdown omitted |

There is no secondary window; `resetDescription` is always "Credits".

### Account identity (Automatic mode only)

The same login bootstrap response used to mint the bearer token (`GET
.../login/?continue=...`) also carries a `data.user_profile` object with the signed-in
user's account details. CodexBar reads `user_profile.email` from it and surfaces it as the
provider's `accountEmail` — the same identity field Codex/Claude populate — so the menu card's
account row shows who is signed in, matching those providers' presentation. `loginMethod` is
set to `"Cookie"` whenever an email was resolved this way. This is purely additive enrichment:
a missing/absent `user_profile` or `email` never fails the token mint, it just leaves identity
unset. Manual (`.web` cURL-capture) mode has no equivalent bootstrap call, so `accountEmail`
stays `nil` there.

## Credits history and pacing

When ZoomMate is enabled and history data is available, the menu's Credits card shows a Today/30d
credits dashboard and pacing verdict **inline**, directly under the credits progress bar — on both
ZoomMate's own tab and the Overview aggregate view, matching Claude's/Codex's inline dashboards. It
includes:

- Two KPI tiles, reusing the same `InlineUsageDashboardContent` component Claude/Codex render
  their inline dashboards with: **Today** (emphasized — the current calendar day's summed `cost`
  from `credits/history`, or 0 if nothing posted yet today) and **30d credits** (the sum across the
  full 30-day window). This mirrors Codex's "Today" / "30d cost" tile pair and Claude's "Today" /
  "30d spend" tile, swapping the "$"/cost unit for "credits" since ZoomMate has no dollar-cost
  concept.
- A row of mini usage bars below the tiles, one per calendar day that has ZoomMate usage
  (`credits/history`'s per-event ledger summed by day), capped at the most recent 30 days, rendered
  in ZoomMate's brand color (`#0B5CFF`) — matching Codex/Claude's own bar density and per-provider
  coloring exactly.
- A pacing line ("Pace: on track" / "Pace: N% ahead of budget" / "Pace: N% behind budget") rendered
  as a plain inline-dashboard detail line below the mini-bars. It's computed from `credits/status`'s
  `budget_cap`, cumulative `used_credit`, and the current billing cycle's
  `cycle_start_date`/`cycle_end_date` — comparing actual usage against the expected
  linear-elapsed-fraction of the cycle. This reuses `UsagePace`'s existing stage thresholds (on
  track / slightly ahead / ahead / far ahead / slightly behind / behind / far behind) rather than
  a ZoomMate-specific scale, so the wording matches other CodexBar pacing indicators.

`is_deleted` history records are excluded from both the KPI tiles and the mini-bars; still-running
sessions (`is_running: true`) are included since their `cost` reflects consumption so far. The
30-day window is enforced independently at both fetch time (the request's `start_time`) and
display time (`dailyBreakdown()` filters to the trailing 30 calendar days regardless of what the
fetch returned), so the chart's calendar span is guaranteed either way. The pacing line only needs
the always-fetched `credits/status` snapshot, so it can appear even in refreshes where
`credits/history` fails or returns nothing. The inline section is gated on having either a
non-empty daily breakdown or a computable pacing verdict — an empty/failed history fetch silently
omits the section instead of showing an empty dashboard.

## Status page

ZoomMate's descriptor points at Zoom's public status page,
[zoomstatus.com](https://www.zoomstatus.com/), which is an Atlassian Statuspage.io site — the same
platform Claude's status page already uses. This means the overall-status row and its "Updated …"
subtitle work through CodexBar's existing shared Statuspage.io fetch/parse path with no
ZoomMate-specific fetcher code.

Zoom's status page lists ~300+ components, dominated by heavy per-region duplication for services
unrelated to ZoomMate (Zoom Phone, Contact Center, and CX each repeated across many regions).
Showing all of them in ZoomMate's status drill-down would be noise, so ZoomMate's component submenu
is filtered to a named allowlist:

- Zoom Meetings
- ZoomMate
- My Notes
- Zoom Workflows
- Zoom Developer Platform
- Zoom Support
- Zoom Website

The allowlist matches component/group names exactly (case-sensitive) against whatever the live API
returns, and is tolerant of any subset being renamed or removed on Zoom's side: a missing name is
silently omitted, never an error, and if none of the allowlisted names are present the submenu
falls back to the same "components not loaded" empty state every other provider already has (no
ZoomMate-specific empty-state UI). "Zoom Meetings" and "Zoom Workflows" are themselves groups in
Zoom's data (each with their own child components); an allowlisted group is shown with its full
existing child list when expanded, same as it would be for any other provider.

This allowlist lives in ZoomMate's provider descriptor metadata. Every other provider has no
descriptor allowlist and keeps showing every component their feed returns, unchanged.

## CLI

```bash
codexbar usage --provider zoommate
```

The CLI reuses the cookie header cached by a previous validated refresh; it does not read Chrome's
cookie store itself. If no cached session exists yet (`noSession`), refresh once from the app or
seed the cache from the terminal with `codexbar cookie --provider zoommate` (add
`--allow-keychain-prompt` to acknowledge that Chrome cookie decryption may prompt).

ZoomMate provides no token-cost data and is not yet supported in the CodexBar widget (this
includes the credits history dashboard and status page above — both are app-menu-only).

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `noCapture` | Manual mode is selected but the capture is empty, off-domain, or lacks a parseable `Authorization` header | Paste a fresh cURL capture of the HTTPS `credits/status` request from `ai.zoom.us` or `zoommate.zoom.us` |
| `noSession` | Automatic mode found no cached session and no ZoomMate/Zoom session cookies it may read (background refreshes and the CLI never read Chrome directly) | Sign in to ZoomMate in Chrome and refresh once from the app (or `codexbar cookie --provider zoommate`), or switch to Manual and paste a capture |
| `invalidCredentials` | HTTP 401/403 — the token expired (~hourly) or was revoked | Re-sign-in (auto) or re-paste a fresh capture (manual) |
| `apiError` | Any other non-200 HTTP status | Check ZoomMate's status; retry later |
| `parseFailed` | HTTP 200 body did not contain the expected `credit_status` shape | Open a CodexBar issue with a redacted response sample |

## Key files

- `Sources/CodexBarCore/Providers/ZoomMate/ZoomMateProviderDescriptor.swift` — provider metadata (including `statusPageURL` and the status-component allowlist) and the unified fetch strategy (calls both `credits/status` and `credits/history`)
- `Sources/CodexBarCore/Providers/ZoomMate/ZoomMateUsageFetcher.swift` — credits/status request, cURL parsing, and cookie-to-token minting
- `Sources/CodexBarCore/Providers/ZoomMate/ZoomMateCreditsHistoryFetcher.swift` — credits/history request, paginated with a date-boundary stop, and the `ZoomMateCreditsHistorySnapshot` model
- `Sources/CodexBarCore/Providers/ZoomMate/ZoomMateModels.swift` — response decoding, error taxonomy, window mapping, daily-bucket aggregation (`dailyBreakdown()`), today's-total lookup (`todayCreditsUsed(now:calendar:)`), and pacing verdict computation
- `Sources/CodexBarCore/Providers/ZoomMate/ZoomMateCookieImporter.swift` — Chrome cookie-jar import (macOS only)
- `Sources/CodexBar/InlineUsageDashboardContent.swift` — shared Today/30d KPI-tile + mini-bar view also used by Claude/Codex/OpenRouter/etc.; ZoomMate renders through this same component
- `Sources/CodexBar/MenuCardView.swift` — renders the generic inline-dashboard slot for credits-only stacked cards
- `Sources/CodexBar/StatusItemController+Menu.swift` — `statusComponentsSubmenuProviders` and descriptor-backed `filterStatusComponents`
- `Sources/CodexBar/Providers/ZoomMate/ZoomMateProviderImplementation.swift` — settings pickers and bindings
- `Sources/CodexBar/Providers/ZoomMate/ZoomMateSettingsStore.swift` — cookie source and capture persistence
