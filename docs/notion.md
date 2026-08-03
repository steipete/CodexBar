---
summary: "Notion AI provider auth, usage endpoint, and allowance windows."
read_when:
  - Adding or modifying the Notion AI provider
  - Debugging Notion cookie import or usage parsing
  - Explaining Notion AI setup
---

# Notion AI Provider

The Notion AI provider tracks the **Rolling** (6-hour) and **Monthly** (billing period) usage allowance
windows that Notion shows in **Settings → Notion AI → Usage**.

Notion begins enforcing the AI usage allowance on **August 3, 2026**. Before that date the same endpoint
reports `"enforcement": "preview"` while still returning real usage numbers, so the gauges are accurate
either way.

> **Unsupported integration:** CodexBar uses Notion's internal, cookie-authenticated `/api/v3` endpoints.
> These endpoints are not a supported public API and may change or break without notice.

## Requirements

The usage allowance only exists on **Business** and **Enterprise** workspaces. Free, Plus, and personal
workspaces make the endpoint answer `{"status":"not_applicable"}`, and CodexBar surfaces that as a clear
provider error rather than an empty gauge.

## Setup

### Automatic (recommended)

1. Sign in to Notion in Chrome.
2. Enable **Notion AI** in **Settings → Providers**.

CodexBar imports your browser session cookie automatically and sends it only to `https://app.notion.com`.
The import requires the `token_v2` session cookie; a browser profile that has Notion cookies but no
`token_v2` is skipped rather than used for a request that would fail with 401.

**Note**: Automatic import defaults to Chrome only to avoid probing unrelated browser stores. Callers using
the shared browser-cookie plumbing can still supply an explicit browser list. Chrome cookie decryption may
require macOS Keychain approval.

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

Notion does not support a standalone environment variable or a `--cookie` CLI flag for this provider. The
only manual paths are the Settings fields above and `config.json`.

## Data Source

CodexBar sends two POST requests per refresh, both to `https://app.notion.com`:

1. `/api/v3/getSpaces` — resolves the signed-in user (email, name) and the workspaces the account can see,
   including each workspace's `plan_type` and `subscription_tier`. This is what makes automatic workspace
   selection and the account identity line possible.
2. `/api/v3/getCreditRateLimitStatus` with `{"spaceId": "<uuid>"}` — the allowance itself.

The rate-limit response looks like this:

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

| CodexBar window | Notion field | Notes |
| --- | --- | --- |
| Rolling (primary) | `window.used` / `window.limit` | `window.window` (`6h`) sets the window length; `resetsInSeconds` sets the reset time. |
| Monthly (secondary) | `billingPeriodWindow.used` / `.limit` | `periodEndMs` sets the reset time; the window has no fixed length. |
| Identity | `getSpaces` | Account email, workspace name, and the capitalized subscription tier. |

Usage is reported against the returned `limit` rather than assumed to be a percentage, so a future
non-100 limit keeps working. Over-quota values are preserved rather than clamped; display clamping happens
downstream.

Custom Agents and Workers are **not** covered by this allowance — Notion meters those with Notion credits
(`getAIUsageEligibilityV2`), which this provider does not read.

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
