---
summary: "SiliconFlow prepaid balance from the China console session or the international API key."
provider_id: siliconflow
provider_name: SiliconFlow
provider_source: Browser session for the China (CNY) console balance; API key for the international (USD) balance.
plugin_scope: Read-only balance on both engines; China uses validated console sessions, international the user-info API. No inferred quota or reset.
read_when:
  - Configuring SiliconFlow
  - Debugging SiliconFlow balance
---

# SiliconFlow

Enable **SiliconFlow** in **Settings → Providers**. China (CNY) is the default region; set the API URL to
`https://api.siliconflow.com` for an international (USD) account. A saved API URL takes precedence over
`SILICONFLOW_BASE_URL`; otherwise the environment value selects the region.

## China: browser session

SiliconFlow retired the China `GET /v1/user/info` balance API on August 14, 2026
([release notes](https://docs.siliconflow.cn/docs/release-notes/overview)). China accounts therefore read the
balance shown in the console. Sign in to `cloud.siliconflow.cn` in a supported browser and leave **Cookie source** on
**Automatic**; no API key or subject ID is needed.

```sh
codexbar usage --provider siliconflow --source web --json
```

Each refresh walks the browser sessions offered by the shared cookie importer and access gate. For each session:

1. `GET https://cloud.siliconflow.cn/me/expensebill` without a subject. The page body is ignored; the active subject
   comes from the `x-subject-id` response header.
2. `GET https://cloud.siliconflow.cn/walletd-server/api/v1/subject/profile/peek` with the same session and that
   `x-subject-id`.

The first session whose wallet response parses is cached; the subject is rediscovered on every refresh and never
stored. HTTP 401, or a redirect to `https://account.siliconflow.cn/login`, rejects that session and tries the next.
When all fail, CodexBar asks you to sign in again in the browser. HTTP 403 reports that console balance access was
denied and asks you to check billing access in the console; 429 is rate limiting, and 408/5xx are temporary failures.
None of these discard the session, and any other 3xx response that reaches the plugin fails the refresh. The shared transport refuses
cross-origin and non-HTTPS redirects, so no cookie reaches `account.siliconflow.cn`; a same-origin HTTPS redirect is
followed with cookies reselected for its URL. The session cookie (`__SF_auth.session-token`) is set on
`.siliconflow.cn`, so the importer reads both that parent domain and `cloud.siliconflow.cn`; cookies are sent only to
`cloud.siliconflow.cn`.

Wallet amounts are integer strings in 10⁻¹² CNY. **Balance** is `financialInfo.balance`, the only row shown;
`available` and the cumulative `recharged` and `used` totals are not displayed. Zero and negative
balances are kept; missing, empty, fractional, or non-string amounts, a missing or malformed subject header, and any
other response shape fail the refresh without showing a balance.

**Manual** accepts a Cookie header copied from a signed-in `cloud.siliconflow.cn/me/expensebill` request.
**Off** disables China refreshes. `--source api` on the China region still calls the retired API; its HTTP 410 or
code `20092` says the China balance API was retired and asks you to use Auto or Web.

Verified against a personal account's page traffic. Organization subjects, subject switching, and vouchers are not
covered.

## International: API key

International accounts paste an API key, or set `SILICONFLOW_API_KEY`; a saved key takes precedence. Each refresh
makes one non-billable bearer `GET https://api.siliconflow.com/v1/user/info`, console `https://cloud.siliconflow.com`.
It never imports browser cookies. A saved or environment origin may include a trailing `/v1`. Any other host,
scheme, port, path, query, or embedded credential is rejected before the key is sent. The international web console
is not used.

The documented success body is:

```json
{
  "code": 20000,
  "message": "OK",
  "status": true,
  "data": {
    "balance": "0.88",
    "chargeBalance": "88.00",
    "totalBalance": "88.88",
    "status": "normal"
  }
}
```

**Balance** is `totalBalance` and is the menu-bar balance. **Purchased** is `chargeBalance`.
**Bonus** is `balance`, the non-top-up component. SiliconFlow does not return a spending limit, so
CodexBar does not invent a percentage, reset, or pace. A negative total stays visible because an account can be
overdue. Account status is shown only when it is not `normal`. Name, image, and email are ignored. Missing or
non-numeric amounts fail the refresh. No live international account was queried for this integration.

HTTP 401/403, and body code `30014`, ask you to check the API key. HTTP 429 uses the shared rate-limit handling.
HTTP 410 and body code `20092` say the balance query was refused and point to the console (on the China origin,
that the API was retired and the web source should be used). Error messages never
include the response body. Both JavaScript engines use the same bundled plugins.

Public contract: [Retrieve user info](https://docs.siliconflow.com/en/api-reference/userinfo/get-user-info).
The monochrome icon preserves the symbol from SiliconFlow's [official logo](https://siliconflow.cn/logo-new.svg),
whose original fill is `#6E29F5`.
