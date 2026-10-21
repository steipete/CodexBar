---
summary: "Tavily account-plan, API-key, and pay-as-you-go credit usage."
provider_id: tavily
provider_name: Tavily
provider_source: API key for account-plan, per-key, and pay-as-you-go credit totals.
plugin_scope: Account-plan and API-key credits through the public usage API.
read_when:
  - Setting up or modifying the Tavily provider
---

# Tavily

Enable **Tavily** in Settings → Providers and enter a Tavily API key, or set `TAVILY_API_KEY` for the CLI.
The key is saved in CodexBar's local config file when entered in Settings.
Use `codexbar usage --provider tavily --source api` to fetch it.

The bundled JavaScript plugin reads `GET https://api.tavily.com/usage` with bearer authentication. It displays
**Account plan** usage from `account.plan_usage` / `account.plan_limit` and **API key** usage from
`key.usage` / `key.limit` as separate meters. Pay-as-you-go totals, when reported, appear in a separate detail
section. Credit totals come directly from Tavily, so differing search, extract, crawl, map, and research
costs are already accounted for; CodexBar does not turn request counts into estimated credits.

A null key limit means **Unlimited**. Zero limits and unlimited keys retain their detail rows without an
invented usage percentage. Remaining credits are the nonnegative difference between the reported cap and
usage for that same scope. Missing or malformed required totals fail the refresh instead of becoming zero.
The returned plan name identifies the account plan; no email or account ID is inferred.

Tavily limits `/usage` to **10 requests per 10 minutes**, including both development and production keys.
Keep refreshes at least one minute apart and avoid repeated manual refreshes. A throttled request fails as
rate-limited without an automatic replay. The endpoint does not expose live request-rate headroom or an
exact reset timestamp. Tavily documents monthly credits resetting on the first day of each month, but does
not specify the timezone here; CodexBar does not invent a reset countdown. No browser session, local
credential discovery, or account mutation is used.

Sources: [Usage API](https://docs.tavily.com/documentation/api-reference/endpoint/usage),
[rate limits](https://docs.tavily.com/documentation/rate-limits),
[credit costs](https://docs.tavily.com/documentation/api-credits), and
[monthly resets](https://help.tavily.com/articles/3116968635-when-do-my-monthly-api-credits-reset).
