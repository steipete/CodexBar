---
summary: "Linkup credit balance through its read-only account API."
provider_id: linkup
provider_name: Linkup
provider_source: API key for the current prepaid USD credit balance.
plugin_scope: Bearer-authenticated credit balance on both engines; no inferred allowance, usage, or reset.
read_when:
  - Configuring Linkup
  - Debugging Linkup balance fetching
---

# Linkup

Enable **Linkup** in Settings → Providers and enter a Linkup API key, or set `LINKUP_API_KEY` for the CLI.
The setting is saved in CodexBar's local config file. CodexBar sends the key only to `https://api.linkup.so`
as `Authorization: Bearer …` and does not import browser cookies or start a login flow.

The bundled JavaScript plugin reads `GET /v1/credits/balance` and displays the numeric `balance` as USD.
Linkup denominates prepaid credits in USD; the May 2026 currency transition preserved existing balances at parity.
Zero and negative values remain visible. Missing, malformed, or nonfinite values fail parsing instead of becoming zero.

Eligible accounts are topped back up to $20 each month; this is a top-up to a cap, not an additive monthly grant.
The endpoint does not report eligibility, next top-up time, consumed credits, or request-rate headroom.
CodexBar therefore shows the reported balance without a percentage, guessed reset, or invented monthly allowance.
Purchased funds can take the balance above $20. Open the provider's billing dashboard for consumption and top-ups.

```sh
codexbar usage --provider linkup --source api --json
```

Sources checked October 8, 2026:
- [Credit balance endpoint](https://docs.linkup.so/pages/documentation/endpoints/account/balance)
- [OpenAPI schema](https://api.linkup.so/v1/openapi.json)
- [Authentication](https://docs.linkup.so/pages/documentation/platform/authentication)
- [Pricing and top-up semantics](https://docs.linkup.so/pages/documentation/platform/pricing)
- [USD pricing transition](https://docs.linkup.so/pages/changelog/usd-pricing)

Tests use the documented balance schema with synthetic values on QuickJS and JavaScriptCore.
No authenticated account was probed during implementation.
