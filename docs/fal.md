---
summary: "fal credit balance through the documented Platform API billing endpoint."
provider_id: fal
provider_name: fal
provider_source: API key with billing read access for the current account credit balance.
plugin_scope: Fixed-origin `Key` GET for the account credit balance on both engines; no inferred allowance, usage, or reset.
read_when:
  - Configuring fal
  - Debugging fal balance fetching
---

# fal

Enable **fal** in Settings → Providers and enter a fal API key, or set `FAL_KEY` for the CLI.
The setting is saved in CodexBar's local config file; configured keys take precedence over the environment.
CodexBar sends the key only to `https://api.fal.ai` as `Authorization: Key …` and does not import browser
cookies or start a login flow.

The key needs the `billing:usage:read` permission. The `BILLING`, `READONLY`, and `FULL` presets on
[fal.ai/dashboard/keys](https://fal.ai/dashboard/keys) include it; an inference-only key returns HTTP 403, which
CodexBar reports as a permission problem rather than an expired key.

The bundled JavaScript plugin reads `GET /v1/account/billing?expand=credits` and displays
`credits.current_balance` in `credits.currency` (USD when the code is missing or malformed). The account
`username` is shown as the organization. Zero balances remain visible. A numeric string balance is accepted;
any other missing, malformed, or nonfinite balance fails parsing instead of becoming zero.

A response can return HTTP 200 without a usable `credits` block. CodexBar reports the balance as unavailable
and keeps the last good value; it never substitutes zero. The cause of the contributor-reported response was
not captured, so a later refresh is not guaranteed to succeed.

The endpoint does not report consumption, a monthly allowance, or a reset time, so CodexBar shows the balance
without a percentage or guessed reset. Open the billing dashboard for usage history and top-ups.

```sh
codexbar usage --provider fal --source api --json
```

Sources checked October 11, 2026:
- [Account billing endpoint](https://fal.ai/docs/platform-apis/v1/account/billing)

The monochrome icon uses the mark from the [fal.ai](https://fal.ai/) site header.
Tests use the documented billing schema with synthetic values on QuickJS and JavaScriptCore.
No authenticated account was probed during implementation.
