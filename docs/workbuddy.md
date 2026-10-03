---
summary: "WorkBuddy provider: website session cookies and the monthly credits allowance from the WorkBuddy billing API."
provider_id: workbuddy
provider_name: WorkBuddy
provider_source: Chrome or manual www.workbuddy.cn cookies for the monthly credits allowance, plan name, and cycle reset.
plugin_scope: Host-owned website session cookies with the matching Chrome User-Agent; billing summary plus optional package listings for the cycle reset on both engines.
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

In Settings → Providers → WorkBuddy, choose a cookie source:

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

Automatic mode tries the next session when every User-Agent attempt returns HTTP 401. Permission
failures, rate limits, service errors, non-zero API codes, and malformed payloads stop retries without rejecting the
session.

## Request contract

The plugin declares a bundled `cookiePolicy` (`request-url`, `validated-single-entry`, `access-gated`). Cookie values
stay in the host: the script passes `cookieSession: session.id`, and the host attaches the matching `workbuddy.cn`
cookies to each request. A session is accepted into the cache only after a successful summary response.

- `get-user-resource-summary` (required): `data.Packages[]` with `CycleTotalCapacity`, `CycleRemainCapacity`, and
  optional `CycleFrozenCapacity` (decimal strings), `CapacityUnit` (`credits`), plus `SubscriptionPackageName`.
  Only `credits` packages are summed.
- `get-user-resource-paid-packages` and `get-user-resource-free-packages` (optional, `{"PageNumber":1,"PageSize":100,
  "PackageCodes":[…],"Status":[0,3]}`): `data.Accounts[].CycleEndTime` supplies the reset time. The listings reject
  requests without `PackageCodes` (HTTP 400, code `10001`), so the plugin sends the paid and free package codes used by
  the WorkBuddy 5.6.2 client; packages added later are not considered for the reset. A failed or unexpected listing
  leaves the reset unknown and keeps the balance.

Responses must have HTTP 200 and `code: 0`. Billing responses also contain account identifiers (UIN, app, account,
order, and resource IDs); the plugin never uses, displays, or logs them.

## Data shown

| Field | Display |
| --- | --- |
| Summed `CycleTotalCapacity` / `CycleRemainCapacity` | One **Credits** meter when the total is above zero, with `450 / 500 credits left` under the bar. Used is `total − remaining`, so rollover above the grant shows 0% used. |
| Earliest future `CycleEndTime` | The meter's reset line. The value has no zone and is read as China Standard Time (UTC+8), one second after the inclusive end, matching the dashboard. |
| `CycleFrozenCapacity` | A **Reserved** row when above zero, as reported. |
| `SubscriptionPackageName` | Header plan label, as returned (for example `体验版` for the free tier). |

**Left** and **Total** rows appear instead of the meter when the total is zero.

## Limitations

- The website billing routes are undocumented and can change without notice.
- Paid-package and per-request usage (`get-user-request-usage`) shapes were checked only on a free-tier account.
- CodeBuddy accounts share the billing system, but signing in on `www.codebuddy.cn` is not verified to authorize the
  `www.workbuddy.cn` origin.
- Local WorkBuddy session history (`~/.workbuddy/projects/`) is not read.
