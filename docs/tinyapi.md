---
summary: "TinyApi available credit balance through a signed-in browser session."
provider_id: tinyapi
provider_name: TinyApi
provider_source: Chrome or manual session cookies for aggregate available credits.
plugin_scope: Console credit balance on both engines; no inferred monthly allowance, pool split, or reset.
read_when:
  - Configuring TinyApi
  - Updating the TinyApi console credit contract
---

# TinyApi

TinyApi is an opt-in bundled JavaScript provider. It reads the account's available credit balance from
`GET https://tinyapi.rest/api/user/credits` and displays **Available credits** in the card, menu bar and CLI.

## Authentication

Enable **Settings → Providers → TinyApi**, then sign in at [tinyapi.rest](https://tinyapi.rest/dashboard).
Automatic imports the signed-in session from Chrome. Manual accepts a complete Cookie header copied from a
signed-in request to `tinyapi.rest`; this includes the `__Secure-authjs.session-token` cookie, or its numbered
chunks. The header is sent unchanged to the same origin. Off disables cookie access and requests.

Manual headers also work in the CLI with `codexbar usage --provider tinyapi --source web`.
Automatic browser import is macOS-only. API keys for TinyApi's tool-execution API are not used: the credits
endpoint belongs to the authenticated web console.

## Display and limits

The response's `data.totalAvailable` is an aggregate credit balance. TinyApi's [pricing](https://tinyapi.rest/pricing)
distinguishes recurring free credits from purchased credits, but the verified console consumer does not expose
that split. CodexBar therefore shows only the returned total. It does not infer a monthly quota, purchased-only
balance, renewal date, current rate-limit headroom, or USD value. Zero credits is a valid balance; malformed
responses fail visibly instead of becoming zero. History and widgets are unavailable for this balance-only source.

The endpoint and `success` / `data.totalAvailable` contract were identified in the public JavaScript used by
[TinyApi's tool page](https://tinyapi.rest/tools/ai-code-explain) on October 8, 2026.
Its unauthenticated response is HTTP 401 with an `UNAUTHORIZED` error. Tests use synthetic fixtures on both plugin
engines; authenticated dashboard parity has not been verified with a real account. The plugin never executes a
tool or spends credits while refreshing.
