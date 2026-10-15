---
summary: "Claude Platform (Claude Console) API credit balance, credit grants, and month-to-date spend via the platform.claude.com browser session."
provider_id: claudeplatform
provider_name: Claude Platform
provider_source: Browser or manual platform.claude.com session cookies for Console API credit balance, expiring credit grants, and month-to-date spend.
plugin_scope: Opaque sessionKey cookie; API-organization credit balance, grants, and optional spend on both engines.
read_when:
  - Configuring Claude Platform
  - Debugging Claude Console credit balance or spend
---

# Claude Platform

Claude Platform shows the API credit balance of your Claude Console organization at
<https://platform.claude.com>. It sits beside the [Claude](claude.md) provider the way OpenAI API sits beside Codex:
Claude tracks Claude.ai/Claude Code subscription limits, while Claude Platform tracks prepaid API credits. The two
providers never share identity, plan, or session data.

## Authentication

Enable Claude Platform in Settings → Providers and sign in at <https://platform.claude.com>. Automatic import reads
the `sessionKey` cookie for `platform.claude.com` in CodexBar's default browser order, which covers every browser in
the shared catalog (including Brave); the Cookie source description lists them. Import follows the host's
browser-access gate: use **Refresh** beside **Cookie source** (or the menu's Refresh action) to authorize the import;
scheduled refreshes never prompt. To keep CodexBar away from every browser store, choose **Manual** in Settings → Providers → Claude
Platform → **Cookie source** (config: `"cookieSource": "manual"` plus `cookieHeader`), and paste a Cookie request
header from a signed-in platform.claude.com request; it should contain `sessionKey`. Manual cookies are stored in the
CodexBar config file. **Off** (`"cookieSource": "off"`) disables cookie access. HTTP 401 from the organization list
or credit balance request, or HTTP 403 from the organization list, rejects that session and tries the next browser
profile; when every candidate is rejected the error asks you to sign in at platform.claude.com again.

Why cookies: the Anthropic Admin API (`sk-ant-admin…`) is unavailable for individual Console accounts, and inference
API keys cannot read billing. The Console session is the only credential that can read an individual organization's
balance.

## Data

These are undocumented Console endpoints used by the platform.claude.com billing page, so they may change without
notice. CodexBar only issues read-only GETs:

- `/api/organizations` lists organizations. Every organization whose `capabilities` include `api` is a candidate,
  in listed order; Claude.ai chat organizations in the same list are ignored. An account without an API organization
  reports that it has no Claude Console API organization.
- `/api/organizations/{uuid}/prepaid/credits` supplies the total balance (`amount`, in minor units) and credit grants
  (`promo_tranches` and `tranches`). CodexBar requests it for each candidate in order: HTTP 403 moves to the next
  candidate, and the first readable organization supplies the balance, spend, and organization name. If every
  candidate answers 403 the error reports that billing access was denied. Amounts are divided by
  10^`balance.credits.exponent` (0–4, default 2 when absent). This request is required; a malformed balance fails the
  refresh.
- `/api/organizations/{uuid}/current_spend` supplies month-to-date spend for the selected organization. It is optional:
  a failed (including HTTP 401) or malformed response keeps the balance visible and shows **Spend: Unavailable**.

The menu card shows:

- **API credit**: the soonest-expiring subscription API credit grant (`subscription_api_credit`, for example the
  credit included with a Claude Max plan) that still has credit, as a used-percentage bar with
  `$124.75 of $200.00 left · Expires Oct 28 (UTC)`. When every subscription grant is exhausted this lane is omitted and
  the menu bar falls back to purchased credit.
- **Purchased credit**: the soonest-expiring purchased grant that still has credit (or, when all are exhausted, the
  soonest one), in the same format.
- **Other credit grants**: every other unexpired grant, including exhausted subscription grants, with its own amounts
  and expiry.
- **Prepaid credits**: the total balance, which the menu bar **Balance** element also shows.
- **Billing**: **This month (UTC)** with month-to-date spend, or **Spend: Unavailable**.

Grants whose expiry is at or before the refresh time are dropped; an unparseable expiry is treated as unknown. Credit
grants expire instead of resetting, so their expiry dates are UTC calendar dates shown as detail text rather than reset
countdowns. The organization name and the `Console session` login label are the only identity fields.

CLI: `codexbar usage --provider claude-platform --source web --json`. On Linux use a manual cookie header in the
config; automatic browser import is macOS-only.
