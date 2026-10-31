---
summary: "WorkBuddy provider: website session cookies and the monthly credits allowance from the WorkBuddy billing API."
provider_id: workbuddy
provider_name: WorkBuddy
provider_source: Chrome or manual www.workbuddy.cn cookies for the monthly credits allowance, plan name, cycle reset, and the platform reward credits.
plugin_scope: Host-owned website session cookies with the matching Chrome User-Agent; billing summary plus optional package listings for the cycle reset and the reward expiry on both engines.
read_when:
  - Configuring WorkBuddy credit tracking
  - Debugging WorkBuddy session-cookie or billing parsing
  - Explaining why CodexBar asks for a WorkBuddy website session
---

# WorkBuddy Provider

[WorkBuddy](https://www.workbuddy.cn) is Tencent's desktop AI work assistant. Its usage is billed in credits through
the CodeBuddy / Tencent Cloud Code Assistant billing system. CodexBar shows the amounts reported on the signed-in
**Plans & usage** page (`https://www.workbuddy.cn/profile/plans-usage`).

CodexBar reads the website billing API with a **website session**:

```text
POST https://www.workbuddy.cn/billing/meter/get-user-resource-summary
Cookie: …
{}
```

## Authentication

WorkBuddy is off by default. In Settings → Providers → WorkBuddy, enable it and choose a cookie source:

- **Automatic:** sign in to `www.workbuddy.cn` in Chrome, then refresh once (or run
  `codexbar cookie refresh --provider workbuddy --allow-keychain-prompt`). Only Chrome is queried. The imported
  session is cached after the billing API accepts it, so later background refreshes do not need a Keychain prompt.
- **Manual:** paste the Cookie header from a Chrome request to `www.workbuddy.cn/profile/plans-usage` into
  **Cookie header**. It stays pinned to that account with no Chrome fallback.
- **Off:** disables cookie access and billing requests.

The WorkBuddy desktop app calls the same endpoints with its own bearer token, which it stores encrypted under
`~/.workbuddy/`. CodexBar never reads or decrypts that token.

### User-Agent binding

WorkBuddy binds the website session to the browser User-Agent: the same cookies return HTTP 401 with any other
User-Agent, including an older Chrome version. Chrome's reduced User-Agent differs only by major version, so CodexBar
reads the installed Chrome version (`/Applications/Google Chrome.app` or `~/Applications/Google Chrome.app`) and sends
`Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/<major>.0.0.0 Safari/537.36`.
If that is rejected, it retries once with the previous major version, which covers an installed Chrome update that
has not been relaunched yet. Manual cookies therefore need to come from that Chrome. Without a readable Chrome
version the request has no browser User-Agent and is expected to fail as an expired session.
This binding is why WorkBuddy retains Chrome-only import instead of the shared browser order. Authentication currently
requires Chrome on macOS; the Linux CLI cannot discover a matching browser User-Agent.

Automatic mode tries the next session when every User-Agent attempt returns HTTP 401. Permission
failures, rate limits, service errors, non-zero API codes, and malformed payloads stop retries without rejecting the
session.

## Request contract

The plugin declares a bundled `cookiePolicy` (`request-url`, `validated-single-entry`, `access-gated`). Cookie values
stay in the host: the script passes `cookieSession: session.id`, and the host attaches the matching `workbuddy.cn`
cookies to each request. A session is accepted into the cache only after a successful summary response.

- `get-user-resource-summary` (required): `data.Packages[]` with `CycleTotalCapacity`, `CycleRemainCapacity`, and
  optional `CycleFrozenCapacity` (decimal strings), `CapacityUnit` (`credits`), plus `SubscriptionPackageName`.
  Only `credits` packages are summed. Optional `data.CreditGroups[]` splits the same allowance by origin
  (`Kind`: `plan_base`, `plan_bonus`, `addon`, `benefit`); only `benefit` is read, for the reward window, and an
  unexpected group shape is ignored rather than failing the balance.
- `get-user-resource-paid-packages` and `get-user-resource-free-packages` (optional, `{"PageNumber":1,"PageSize":100,
  "PackageCodes":[…],"Status":[0,3]}`): `data.Accounts[].CycleEndTime` supplies the reset time. The listings reject
  requests without `PackageCodes` (HTTP 400, code `10001`), so the plugin sends the paid and free package codes used by
  the WorkBuddy 5.6.2 client; packages added later are not considered for the reset. A failed or unexpected listing
  keeps the balance, including HTTP 401; a successful listing can still supply the reset if the other listing fails.
  Free packages are queried when no future paid reset is available, and also whenever reward credits exist, because the
  per-grant expiries live only in the free listing. Reward grants never supply the main allowance’s fallback reset.
  For reward expiry, `CycleEndTime` is ignored for accounts whose `PackageCode` is not the
  reward code, so the trial grant that closes with the calendar month cannot bound the reward window.
  Both listings share at most five seconds, capped before the overall fetch deadline; a stalled listing cannot consume
  the balance's publication time. Only the first 100 accounts in each listing are considered. Cancelling a refresh still
  stops the fetch.

Responses must have HTTP 200 and `code: 0`. Billing responses also contain account identifiers (UIN, app, account,
order, and resource IDs); the plugin never uses, displays, or logs them.

## Data shown

| Field | Display |
| --- | --- |
| Summed `CycleTotalCapacity` / `CycleRemainCapacity` | One **Credits** meter when the total is above zero, with `450 / 500 credits left` under the bar. Used is `total − remaining`, so rollover above the grant shows 0% used. |
| Earliest future `CycleEndTime` in the paid listing | The meter's reset line. The paid listing carries the subscription cycle, which is what refills the allowance; non-reward free grants only supply the reset when the paid listing has no future cycle end, so the trial grant that closes with the calendar month cannot shorten a paid cycle. The value has no zone and is read as China Standard Time (UTC+8), one second after the inclusive end, matching the dashboard. |
| `CycleFrozenCapacity` | A **Reserved** row when above zero, as reported. |
| `benefit` credit group | A **Rewards** window with its own bar and `621 / 2,139 credits left` under it. These grants are already inside the **Credits** meter; the window only breaks them out. |
| Earliest `CycleEndTime` of the reward grants that still carry credits | A **Reward expiry** row, because reward credits lapse grant by grant instead of resetting; the window carries the balance and no countdown. Spent grants stay in the listing until their cycle ends, and the dashboard ignores them, so they never pull this date forward. Grants without a readable remaining balance are omitted from the expiry lookup. |
| `SubscriptionPackageName` | Header plan label, as returned (for example `体验版` for the free tier). |

**Left** and **Total** rows appear instead of the meter when the total is zero; any reserved credits remain visible.
Amounts use CodexBar's shared number formatting, including thousands separators.

## Limitations

- The website billing routes are undocumented and can change without notice.
- Paid-package and per-request usage (`get-user-request-usage`) shapes were checked only on a free-tier account.
- The reset line follows the paid subscription listing, so purchased (`addon`) credits that end earlier are not
  reflected; the balance can drop before the reset. Reward credits carry their own expiry row instead.
- CodeBuddy accounts share the billing system, but signing in on `www.codebuddy.cn` is not verified to authorize the
  `www.workbuddy.cn` origin.
- Local WorkBuddy session history (`~/.workbuddy/projects/`) is not read.

## Brand mark

The app, website, and CLI dashboard use a monochrome version of the mascot from WorkBuddy’s
[official logo](https://assets.workbuddy.cn/web/workbuddy/a5b2fb510f0e7b156f19d072fae0cd12ae1f2f19/assets/logo.svg).
The template follows the system tint; the existing `#0DC8A6` provider accent is unchanged.
