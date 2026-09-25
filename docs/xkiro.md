---
summary: "xKiro daily free-token allowance through its unmetered usage API."
read_when:
  - Configuring xKiro
  - Debugging xKiro free-token usage
---

# xKiro

xKiro is disabled by default. Add an API key in Settings → Providers → xKiro, or set `XKIRO_API_KEY`.
The setting is stored in CodexBar's local config file. CodexBar sends the key only to `https://api.xkiro.com`
as `Authorization: Bearer …`; it never imports browser cookies or starts a login flow.

The bundled `xkiro.ts` plugin reads `GET /v1/usage`. The provider documents this endpoint as free to call,
consuming no tokens, rate-limit capacity, or spend-window capacity. It reports account-wide counters:
two keys belonging to one account return the same usage.

The daily meter and detail rows use `free_tokens.used_today`, `limit_per_day`, and `remaining`.
The allowance comes from the response, not a hard-coded pricing tier. The daily reset is 00:00 UTC,
as documented for the free-token counter. Paid plan windows and wallet balances do not contribute to this meter.
The plan label is separate from the free-model budget; a pay-as-you-go account can also have free tokens.

Missing counters remain unknown. A null limit is shown as “No cap reported”; no percentage is invented.
Malformed counters fail parsing. There is no guessed RPM limit: the usage endpoint does not expose one.
HTTP 429 is classified as rate limiting and preserves `Retry-After` through the host's bounded retry policy.

```sh
codexbar usage --provider xkiro --source api --json
```

Sources checked September 24, 2026:
- [Usage & limits](https://docs.xkiro.com/api/usage/) — endpoint, authentication, example responses, counter scope, UTC reset.
- [Rate limits](https://docs.xkiro.com/api/rate-limits/) — independent limits and `Retry-After` semantics.

Tests use the documented PAYG response with synthetic identity. No authenticated account response was available
during implementation, so live account behavior remains unverified.
