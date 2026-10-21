---
summary: "X API prepaid dollar balance from the X developer console."
provider_id: xapi
provider_name: X API
provider_source: Browser or manual console.x.com cookies for prepaid and free credits, including negative balances.
plugin_scope: Same-session account discovery and dollar balances through host-owned cookies and CSRF header echo on both engines.
read_when:
  - Configuring X API balance tracking
  - Debugging X developer console authentication
---

# X API

**X API** monitors the prepaid wallet used for X (Twitter) API calls. It is separate from **xAI** inference billing
and **Grok** subscription quotas. Enable it under Settings → Providers → X API; it is disabled by default.

Sign in to [the X developer console](https://console.x.com) in a supported browser and choose Automatic cookies, or paste a
Cookie header from a console request into Manual mode. The header needs `auth_token` and `ct0` from the same session.
Manual cookies also work on Linux with `codexbar usage --provider xapi --source web --json` and the existing provider
config `cookieSource` / `cookieHeader` fields. An X API bearer token does not replace a website session.

The bundled `xapi.js` plugin makes two read-only requests:

1. `GET https://console.x.com/api/me` selects the signed-in account's `account.id`.
2. `GET https://console.x.com/api/accounts/{account.id}/credits` supplies `credits.balance` and `freeCredits.balance`.

The console displays both balances directly as USD; they are not cents or the thousandths used by its spend endpoint.
CodexBar adds purchased and free credits for **Balance**, with separate detail rows for each. Missing free-credit data
means zero as in the console; malformed supplied numbers fail parsing. A negative balance retains its sign in the menu,
CLI JSON, and **Balance** layout token. No quota percentage, reset time, or token count is inferred.
JSON exposes the amount as `providerCost.balance`; its required `used`/`limit` values stay neutral at zero, without
inferring spend or a budget. The menu shows one credits section.

Cookie values remain in the host. Imports follow the shared browser order for `x.com` and `console.x.com` cookies, selected for the
request URL. The host copies the selected `ct0` cookie into `X-CSRF-Token` for `console.x.com` only. The script cannot
read cookies or send requests to any other origin. Imported sessions are not persisted by this provider. Off mode makes
no requests; expired sessions can advance to another automatic profile, while manual mode remains pinned.

If multiple browsers are blocked, the shared cookie diagnostic lists each browser's recovery action. Chrome profile access needs **System Settings → Privacy & Security → Files & Folders → CodexBar → Google Chrome**; Safari cookie access may need **Full Disk Access** for CodexBar. A Safari denial no longer hides Chrome's profile guidance. This changes error reporting only, without extra cookie reads or permission prompts.

Use a refresh interval of at least five minutes if the console rate-limits requests. HTTP 429 is reported as rate
limited, without an immediate retry. The integration follows CodexBar's shared refresh interval; it does not introduce
an independent polling timer. Recent spend, payment controls, plan history, and widgets are outside this integration.

## Source contract

The request and field mappings were checked against the console's public JavaScript on October 7, 2026:
[credits request](https://ton.twimg.com/dataproducts/developerconsole/_next/static/chunks/1005-e5d4349396137291.js),
[balance rendering](https://ton.twimg.com/dataproducts/developerconsole/_next/static/chunks/app/accounts/%5BaccountId%5D/billing/credits/page-0c845e065726a121.js),
and [account discovery and CSRF](https://ton.twimg.com/dataproducts/developerconsole/_next/static/chunks/5299-626a890af1b0e08f.js).
These are internal console routes and can change independently of the public X API. Synthetic fixtures cover both
plugin engines; an authenticated account response was not captured during implementation. An unauthenticated
`/api/me` request returned the console's HTTP 400 / error-code 215 session error, which is also covered by fixtures.
