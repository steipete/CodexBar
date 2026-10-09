---
summary: "Aerostack monthly AI-token usage from its account billing API."
provider_id: aerostack
provider_name: Aerostack
provider_source: Explicit account JWT for monthly AI tokens used and the observed account allowance.
plugin_scope: Fixed-origin bearer GET for account AI-token counters and the reported period on both engines; no login, reset inference, or agent execution.
read_when:
  - Configuring Aerostack
  - Debugging Aerostack monthly usage
---

# Aerostack

Aerostack is disabled by default. Enter an **account JWT** in Settings → Providers → Aerostack, or set
`AEROSTACK_TOKEN`. The masked setting is saved in CodexBar's local config file. This is the account bearer token
used by the billing API, not an Agent Endpoint key (`aek_…`) or an upstream LLM key. Replace it when it expires;
CodexBar does not sign in, refresh tokens, or import browser credentials.

The bundled `aerostack.ts` plugin makes one read-only request:

```text
GET https://api.aerostack.dev/api/billing/usage
Authorization: Bearer <account JWT>
```

The monthly meter uses the response's `usage.ai_tokens.used` and `usage.ai_tokens.limit`. Detail rows show the
observed usage, allowance, remaining tokens, any usage above the allowance, and the reported `period` (for example,
`2026-03`). The `tier` supplies the plan label. The account's returned limit is authoritative: the marketing and
billing documentation currently list different Free allowances, so neither value is hardcoded.

Missing counters remain unknown. A zero or absent allowance has no percentage meter; any reported counters remain
visible. Usage above the allowance is not a claim that the account is blocked: Aerostack documents a grace buffer.
Invalid counters fail parsing without including response content in the error.

The usage contract has no reset timestamp, timezone, live Agent Endpoint rate headroom, or wallet balance.
CodexBar does not derive a reset from the period label or subscription end, sum per-run history, execute agents,
or combine prepaid funds with recurring token allowances.

```sh
codexbar usage --provider aerostack --source api --json
```

Sources checked October 8, 2026:
- [Billing & Plans](https://docs.aerostack.dev/billing/) — account JWT authentication, usage schema, period, and grace buffer.
- [Plans](https://docs.aerostack.dev/billing/plans/) — monthly quota context and per-account Enterprise overrides.
- [Agent Endpoint pricing](https://docs.aerostack.dev/agent-endpoints/pricing/) — per-run costs and static rate limits are distinct from account quota.

Tests use public documented response shapes with synthetic values on both JavaScript engines. No live account
was used to verify this integration.
