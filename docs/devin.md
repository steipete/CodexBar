---
summary: "Devin provider auth, quota endpoint, and setup."
read_when:
  - Adding or modifying the Devin provider
  - Debugging Devin localStorage import or quota parsing
  - Explaining Devin setup
---

# Devin Provider

The Devin provider supports Standard Devin and optional Devin Enterprise usage. Leave **Enterprise host** empty to keep
the existing Standard Devin behavior.

## Standard Devin

Standard Devin tracks included daily and weekly usage quotas from [app.devin.ai](https://app.devin.ai).

### Setup

1. Sign in to Devin in Google Chrome.
2. Open the organization Usage & Limits page once.
3. Enable **Devin** in **Settings → Providers**.

Automatic mode reads only the Devin session and organization metadata from Chrome localStorage. It does not scan other
browsers or import other sites' sessions. Current decoded session values take precedence over raw storage fallback
data. CodexBar sends the session token only to `https://app.devin.ai`.

For accounts with multiple organizations, set **Organization** to select one explicitly. An internal `org-...` or
`org_...` ID takes precedence over Chrome's cached organization metadata. A slug uses only its matching cached ID;
open that organization's Usage & Limits page in Chrome if the metadata is missing.
Inferred names and internal IDs must belong to the same storage record or JSON object. Incomplete metadata never
borrows an ID from another organization, and an explicit selection prefers its complete matching record.

### Manual Auth

In the CodexBar menu bar app:

1. Open [app.devin.ai](https://app.devin.ai) in the browser where you are signed in and select your organization.
2. Open Developer Tools (in Chrome: **View → Developer → Developer Tools**, or **Option–Command–I**).
3. Select the **Network** tab, then open or reload the organization's **Usage & Limits** page.
4. Filter requests by `billing/quota/usage` and select a successful request (status **200**).
5. Under **Headers → Request Headers**, copy the **Authorization** value, including `Bearer `.
6. Open **CodexBar Settings → Providers → Devin**, set **Auth source** to **Manual**, and paste it into **Bearer token**.
7. From the same request, copy **x-cog-org-id** into **Organization**, then refresh Devin in CodexBar.

The Bearer token field also accepts the bare token or a full `Authorization: Bearer ...` header line. These are Devin
browser session credentials, not Codex CLI credentials. Signing in to Codex CLI does not sign in to Devin. Keep the token
private; do not include it, a Cookie header, or an unredacted Network screenshot in an issue report.

The organization field also accepts a slug or the full organization URL, but the internal `org-...` or `org_...` ID from
the successful request is the most direct manual setup. Manual mode does not import a browser session. When a session
expires, sign in to Devin again and repeat these steps with a new successful request.

Some Auth1 sessions need the internal organization ID even when the same token works in the browser. If Devin returns
`No organizations found for auth1 user`, CodexBar reports organization guidance rather than treating the token as expired:

1. Open the organization's **Usage & Limits** page in the browser where you are signed in.
2. In Developer Tools → Network, inspect a successful `/billing/quota/usage` request.
3. Copy its `x-cog-org-id` request-header value into CodexBar's **Organization** field, then refresh.

The internal-ID path is already supported; manual mode does not discover IDs from public slugs. Other 401/403 responses
still report invalid or expired credentials. For automatic auth with missing organization metadata, open the
organization's Usage page in Chrome and refresh.

Environment overrides:

- `DEVIN_BEARER_TOKEN` or `DEVIN_AUTHORIZATION`
- `DEVIN_ORGANIZATION` or `DEVIN_ORG`

### CLI (macOS and Linux)

Automatic Chrome session import is macOS-only. For manual auth on either platform, configure
`~/.config/codexbar/config.json` (or your existing legacy config):

```json
{
  "version": 1,
  "providers": [{
    "id": "devin",
    "cookieSource": "manual",
    "cookieHeader": "Bearer YOUR_DEVIN_TOKEN",
    "workspaceID": "org_YOUR_ORGANIZATION"
  }]
}
```

Run `codexbar usage --provider devin`. You can omit `cookieHeader` when supplying
`DEVIN_BEARER_TOKEN` or `DEVIN_AUTHORIZATION`, but keep `cookieSource` set to `manual`.
The organization environment overrides also apply. Environment tokens take precedence
without enabling automatic auth; an empty override does not fall back to the configured token.

### Automatic auth troubleshooting

- Automatic import supports Google Chrome profiles only. Being signed in to Safari, Firefox, Arc, or another browser
  does not provide a Devin session to CodexBar. Open `app.devin.ai` and the organization's Usage & Limits page in Chrome.
- Devin uses Chrome's **localStorage**, not its Cookies database. CodexBar reads `auth1_session` (an `auth1_` token) or
  Auth0 cached `access_token` / `accessToken` values for `app.devin.ai`. Cookies for `.devin.ai` or `api.devin.ai`, Chrome
  Safe Storage Keychain permissions, and Safari cookie permissions are not part of this import path.
- A **no session** error means no supported session was found in the discovered Chrome storage. A **could not read
  Chrome local storage** error means a discovered store could not be opened; it does not mean Devin rejected your token.
  Reopen Chrome and its Devin Usage & Limits page, refresh CodexBar, or use Manual auth above.
- A **token rejected** error means Devin returned an authentication rejection. Sign in again or replace the manual
  token. A **missing organization** error instead needs the organization setup described above.

When reporting a failure, include the CodexBar, macOS, and Chrome versions, your selected Auth source, the browser used
for Devin, and the exact error text. Do not share session values.

### Data Source

CodexBar requests:

```text
GET https://app.devin.ai/api/<internal-org-id>/billing/quota/usage
```

The response supplies daily and weekly usage percentages plus reset timestamps. CodexBar omits the daily quota when Devin sets `hide_daily_quota` to `true`, while retaining weekly usage and extra balance.
If Devin changes or expires the browser
session, sign in again and refresh CodexBar.

#### Browser token lifetime

Devin's web session uses Auth0 access tokens that live about 30 minutes. The webapp refreshes them silently while a tab
is open, and Chrome writes the refreshed token to its local storage on disk. CodexBar imports the freshest token it can
find (by JWT expiration), so usage tracking works while the webapp has been active recently. If the last browser
activity is older than the token lifetime, the on-disk token is expired and CodexBar reports invalid credentials until
you open the webapp again. Manual auth avoids that dependency when a long-lived token is available.

## Devin Enterprise

Devin Enterprise deployments use a dedicated host, for example `your-team.devinenterprise.com`, and expose personal
monthly **ACU cycle** usage instead of Standard Devin's Daily/Weekly quotas. To enable this mode, set **Enterprise host**
in **Settings → Providers → Devin** to the deployment host. Enter a bare host such as
`your-team.devinenterprise.com`, or its HTTPS origin. Do not include a path, query, or fragment.

Sign in to that Enterprise deployment in Chrome and make sure your account has **View Personal Analytics** permission.
CodexBar uses the existing Devin browser-session discovery for the configured origin and its Auth0 session. It reads only
the signed-in user's personal analytics from that origin. This browser session is required even if **Auth source** is set
to **Manual**; the manual Bearer token field is for Standard Devin's `app.devin.ai` origin.

```text
GET https://<enterprise-host>/api/personal-analytics/usage-limit
```

CodexBar displays the monthly cycle as the primary usage window, with **ACUs used**, **ACUs total**, and **ACUs left** in
the shared provider details. The `cycle_end` value is shown as the reset date. When Devin supplies both `cycle_start` and
`cycle_end`, CodexBar uses their actual interval for the window duration. If `cycle_start` is absent or invalid, the
duration stays unknown instead of assuming a 30-day cycle.

With **Enterprise host** empty, CodexBar uses the existing Standard Devin session and quota endpoints on
`app.devin.ai`; it does not contact an Enterprise host.
