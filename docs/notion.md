---
summary: "Notion AI provider auth, usage endpoint, and allowance windows."
read_when:
  - Adding or modifying the Notion AI provider
  - Debugging Notion cookie import or usage parsing
  - Explaining Notion AI setup
---

# Notion AI Provider

The Notion AI provider tracks three independent credit pools for the selected workspace:

- **Standard**: the current user's monthly credits for everyday Auto usage.
- **Select**: the current user's monthly credits for selected models and applicable Custom Agent usage.
- **Notion Credits**: the separate workspace balance reported by the premium-credit endpoint.

When usable Standard/Select allowances are absent, the provider retains the legacy **Rolling** (6-hour)
and **Monthly** (billing period) windows. Selection depends on the response shape, never a migration date.

Notion Credits appear in explicit **Balance** elements. Legacy menu-bar percentage, pace and reset-time
modes continue to display the selected allowance, even when workspace credits are available. Standard and
Select keep their own names in cards, layout lanes and CLI/structured output. Personal credit details
remain visible when optional usage is disabled; the workspace balance follows the optional-usage preference.

Notion begins enforcing the AI usage allowance on **August 3, 2026**. Before that date the same endpoint
reports `"enforcement": "preview"` while still returning real usage numbers, so the gauges are accurate
either way.

> **Unsupported integration:** CodexBar uses Notion's internal, cookie-authenticated `/api/v3` endpoints.
> These endpoints are not a supported public API and may change or break without notice.

## Requirements

The usage allowance only exists on **Business** and **Enterprise** workspaces. Free, Plus, and personal
workspaces can answer `{"status":"not_applicable"}` with no usable allowance. CodexBar surfaces that as a
provider error rather than a fabricated zero. Migrated Business workspaces can also report this legacy
status alongside resolved personal allowances; those allowances take precedence over the legacy status.

## Setup

### Automatic (recommended)

1. Sign in to Notion in a supported browser.
2. Enable **Notion AI** in **Settings → Providers**.

The bundled Notion plugin runs on both engines. The host imports your browser session cookie automatically and sends
it only to `https://app.notion.com`; the script sees an opaque session ID, never the cookie values. Within each profile,
source domains rank as `app.notion.com`, `www.notion.com`, `notion.com`, `www.notion.so`, then `notion.so`.
The import requires the `token_v2` session cookie; a browser profile that has Notion cookies but no
`token_v2` is skipped rather than used for a request that would fail with 401.

**Note**: Automatic import follows the shared supported-browser order. Background refreshes only read Chromium cookies when the no-UI Keychain preflight
confirms existing access; they never request a new permission. Use an explicit Refresh to authorize cookie
decryption when needed, or use Manual mode. An explicit refresh permits at most one browser permission retry.

Validated sessions remain in the shared cookie cache. Background refreshes first reuse the existing owner-only
`notion-session.json` token file, then the shared cache. If neither succeeds, browser reads remain subject to the shared
access gate: background reads require existing prompt-free authorization, while explicit CLI cookie refreshes retain
their acknowledged retry scope. A successful allowance fetch updates both stores; a 401 conditionally clears the rejected session without erasing a newer one. An interactive
cookie refresh commits its replacement only after success, preserving both prior stores on failure.

### Manual

Set **Cookie source** to **Manual** in the Notion AI provider settings, then paste one of:

- The bare `token_v2` value,
- A `Cookie: ...` header value copied from a browser network request to `app.notion.com`, or
- A full `curl` command captured from the Notion web app (all `-H` flags are parsed; only the `Cookie`
  header and a fixed set of safe request headers are forwarded).

To capture the cookie manually:

1. Open [app.notion.com](https://app.notion.com/) in your browser.
2. Open Developer Tools → Network tab.
3. Open **Settings → Notion AI → Usage** and find a `getCreditRateLimitStatus` request.
4. Right-click → Copy → Copy as cURL.
5. Paste the full `curl` command into the **Notion cookie** field in CodexBar settings.

### Workspace selection

Accounts that belong to more than one workspace default to the first workspace on a Business or Enterprise
plan. To pin a specific one, set **Workspace ID** in the provider settings, or `workspaceID` on the
`notion` entry in `config.json`. Both dashed and undashed UUID forms are accepted.

For accounts with many workspaces or members, discovery can exceed the plugin's 5 MiB response limit.
If **Workspace ID** contains a valid UUID, CodexBar then requests allowances directly for that workspace.
Email, account ID, workspace name, and plan are omitted for that refresh because discovery did not complete;
normal-sized discovery still supplies them. Without a valid Workspace ID, the error asks you to configure one.
The shared response limit remains unchanged, including for the allowance request.

Notion does not support a standalone environment variable or a `--cookie` CLI flag for this provider. The
only manual paths are the Settings fields above and `config.json`.

## Data Source

CodexBar sends three POST requests per successful allowance refresh, all to `https://app.notion.com`:

1. `/api/v3/getSpaces` — resolves the signed-in user (email, name) and the workspaces the account can see,
   including each workspace's `plan_type` and `subscription_tier`. This is what makes automatic workspace
   selection and the account identity line possible.
2. `/api/v3/getCreditRateLimitStatus` with `{"spaceId": "<uuid>"}` — the allowance itself.
3. `/api/v3/getAIUsageEligibilityV2` with the same `spaceId` and cookie session — an optional premium-credit
   balance lookup with a three-second request deadline and no retries. HTTP errors (including 401/403),
   network failures, invalid JSON, and absent or malformed balances omit this section while preserving
   the allowance snapshot and validated session. Refresh cancellation still propagates.

A legacy rate-limit response looks like this:

```json
{
  "status": "within_limit",
  "window": { "creditType": "basic_ai_credits", "scope": "per_user", "window": "6h", "used": 42.5, "limit": 100 },
  "resetsInSeconds": 12600,
  "billingPeriodWindow": {
    "creditType": "basic_ai_credits",
    "scope": "per_user",
    "cadence": "billing_period",
    "used": 18.0,
    "limit": 100,
    "periodEndMs": 1788000000000
  },
  "enforcement": "preview"
}
```

## Mapping

### Verified post-migration response

On November 13, 2026, a read-only request using an existing saved session against a Business workspace
returned the real response saved as
`Tests/CodexBarTests/Fixtures/Providers/Notion/get-credit-rate-limit-status-migrated.json`.
The fixture preserves the complete response structure and numeric values; it contains no account or
workspace identifiers, personal information, cookies, tokens, or request headers. It is captured data,
not a synthetic allowance contract. The parser is based on this observed response and the matching UI values.

The same workspace's **Settings → Notion AI → Me** explicitly describes two per-seat monthly balances:

| Pool | API entry | API credit usage / limit | Notion UI |
| --- | --- | --- | --- |
| Standard | `allowances[]`, `bucketId: "auto"` | `credits.used: 134.66869`, `credits.limit: 1500` | 134 used of 1,500; progress 8.98% |
| Select | `allowances[]`, `bucketId: "flex"` | `credits.used: 0`, `credits.limit: 500` | 0 used of 500; progress 0% |

Both entries have `cadence: "billing_period"`, `state: "resolved"`, `limit: 100` and a separate
`credits` object in actual credit units. Their top-level `used` values (8.98 and 0) are percentage-scale
values; they are not the raw credit counts. The rounded Standard percentage must not be used to
reconstruct its exact credit usage. No allowance sizes should be hardcoded from this example.

Both entries report `periodStartMs: 1793196000000` and `periodEndMs: 1795874400000`:
October 28, 2026 at 14:00 UTC through November 28, 2026 at 14:00 UTC. The UI displays
**Oct 28 – Nov 28, 2026**. These exact boundaries define a 31-day billing period, rather than a
six-hour rolling window or a week. Only the observed resolved state is established by this capture;
it does not establish the payloads for other subscription tiers, unresolved states, or missing credit fields.

Crucially, the response's top-level `status` is **`not_applicable`** despite both new allowances being
resolved. Legacy `window` and `billingPeriodWindow` are absent. The two `standard` entries are
`not_exposed`, and the old six-hour windows inside `modelSelectionDecisions` are also `not_exposed`.
Those nested windows do not create visible zero-usage Rolling bars. Each unique resolved `auto`/`flex`
billing-period entry is handled independently. Unavailable, malformed, duplicate or zero-limit buckets
are omitted. If neither personal bucket is usable, legacy parsing is retained. A missing credit count
omits the absolute personal balance while preserving a valid percentage; it never invents a zero.

When valid `credits.used` and `credits.limit` are supplied, the gauge uses their full-precision ratio,
and the Personal credits section shows their remaining balance and raw usage. Percentage-scale values
are a fallback for the gauge only. No workspace balance is derived from either personal allowance.

The same session and workspace's separate `getAIUsageEligibilityV2` lookup reported
`premiumCredits.totalCreditBalance: 300`. The existing **Notion credits** dashboard displayed
**0 / 300 Notion credits** with **Resets Nov 28**; the personal AI settings displayed **0 credits used**
under Purchased Notion credits. These are usage displays, not evidence of a zero remaining balance.
Keep the authoritative balance of 300 separate from both personal balances and do not infer a reset
date or percentage for that balance from the dashboard. No settings, purchases, AI runs, or Keychain
operations were performed during validation.

### Legacy mapping

| CodexBar window | Notion field | Notes |
| --- | --- | --- |
| Rolling (primary) | `window.used` / `window.limit` | `window.window` (`6h`) sets the window length; `resetsInSeconds` sets the reset time. |
| Monthly (secondary) | `billingPeriodWindow.used` / `.limit` | `periodEndMs` sets the reset time, and the window length is the calendar month ending there. |
| Identity | `getSpaces` | Account email, workspace name, and the capitalized subscription tier. |

Usage is reported against the returned `limit` rather than assumed to be a percentage, so a future
non-100 limit keeps working. Over-quota values are preserved rather than clamped; display clamping happens
downstream. The plugin declares `snapshotPolicy: {percent: "preserve-overage"}` to retain this behavior on both engines.

The Notion UI describes Select as covering selected models and Custom Agents, with Notion credits
used after the included personal pools run out. The separate **Notion Credits** section displays only
the finite numeric `premiumCredits.totalCreditBalance` as **Remaining credits**.
An explicit zero remains visible; a missing balance is omitted. `basicCredits`, the top-level `usage` balance,
and per-source limits are not fallbacks. The [redacted fixture in #2888](https://github.com/steipete/CodexBar/issues/2888)
reports `monthlyAllocated.usageTotal = 560`, `limit = 300`, and both balance and overage as zero:
subtracting usage from limit would give the wrong balance.

No premium-credit percentage, reset date, usage total, or overage amount is inferred. Unlike Codex's native
credits integration, this is a generic text detail section without a progress gauge or usage history.
It follows the **Show optional credits and extra usage** preference. In **Menu Bar Layout**, add the existing
**Balance** element to show the reported balance, including zero. Automatic percentages continue to select
the allowance windows, independently of the credits balance. No new layout token or credential is needed.

### Deadlines

The required `getSpaces` and `getCreditRateLimitStatus` POSTs keep their 15-second HTTP deadlines.
The optional premium POST keeps its three-second HTTP deadline and does not retry. The Notion strategy
reserves five seconds above its existing `max(30, webTimeout * 2)` runtime budget: three for the optional
lookup and two for scheduling and snapshot delivery. A 15-second caller configuration therefore gets
35 seconds overall; ordinary app and CLI contexts use `webTimeout = 60` and get 125 seconds.
Other providers retain their existing budgets. Explicit cancellation still interrupts the worker.

The debug probe reports only the available allowances, using Standard/Select or Rolling/Monthly labels.
It disables optional workspace usage and retains its separate
20-second outer deadline, so a premium lookup cannot delay that diagnostic.

### Pace

The monthly card also shows a daily credit target from the reported remaining allowance and the local
calendar days until reset, including today. This does not estimate credits consumed today; Notion does
not report that breakdown. Hiding pace hides the target as well.

Both bars carry an expected-usage estimate on the card and in `codexbar usage`, reading `n% in deficit`
when you are ahead of an even burn and `n% in reserve` when behind.

Standard and Select carry the exact duration between the supplied `periodStartMs` and `periodEndMs`.
Their reset timestamp is preserved exactly. Missing/invalid period boundaries omit pace rather than
assuming a week or a month. A reported 30-day personal period is an actual duration, not the legacy sentinel.

The legacy monthly estimate needs a window length, and Notion reports only `periodEndMs`. The snapshot
therefore carries the shared monthly sentinel, which is what makes the provider's
`ProviderPaceCapability` match; resolution then substitutes the real calendar month ending at the reset
— not a flat 30 days, which would misstate expected usage in February and in any 31-day cycle.

A `nil` length is not a safe alternative. `UsagePace.weekly` substitutes the caller's
`defaultWindowMinutes` (7 days on every weekly path) rather than skipping the window, so a lengthless
billing period would be scored against a week; the surfaces that do refuse a lengthless window drop it
from pacing entirely instead. Every path that scores one of these windows — the card, the menu-bar pace
token, predictive pace warnings, and the CLI — resolves the sentinel first, so they cannot disagree.

The rolling window is paced as a session window. Its length comes from the API's `6h` token rather than
being fixed, so only a window no longer than six hours is paced this way; anything longer is a billing
period and goes through the reset-window path instead.

## Status

Notion publishes a status page at <https://status.notion.so/>; CodexBar links to it but does not poll
components.

## Troubleshooting

- **"Notion AI usage allowance is not tracked for …"** — the selected workspace is not on a Business or
  Enterprise plan. Set **Workspace ID** to a workspace that is.
- **"Notion session cookie is invalid or expired"** — sign in to Notion again, or re-capture the manual
  cookie.
- **"No Notion cookies found"** — the browser profile has no `token_v2` cookie for Notion. Sign in, or
  switch to a manual cookie.
- **"Notion workspace discovery is too large"** — set **Workspace ID** to the UUID of the Business or
  Enterprise workspace to monitor. You can find it in the `spaceId` body field of the
  `getCreditRateLimitStatus` request described in the Manual setup instructions.
