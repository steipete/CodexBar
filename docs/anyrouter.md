---
summary: "AnyRouter prepaid credit balance, plan/top-up split, and spend through the public Credits API."
read_when:
  - Setting up or modifying the AnyRouter provider
---

# AnyRouter

Enable **AnyRouter** in Settings → Providers and enter an AnyRouter API key, or set `ANYROUTER_API_KEY`
for the CLI. The key is saved in CodexBar's local config file when entered in Settings. Use
`codexbar usage --provider anyrouter --source api` to fetch it.

AnyRouter is a hosted model gateway at [anyrouter.dev](https://anyrouter.dev) that fronts many upstream
model providers behind one OpenAI-compatible endpoint. Accounts hold a prepaid USD credit balance, so
there is no rate window to count down; this provider is balance-only.

## Getting a key

Create a key at [dash.anyrouter.dev](https://dash.anyrouter.dev). One detail matters: a key created in
the dashboard starts with the inference endpoints enabled and **management endpoints turned off**, and
`/api/v1/credits` is a management endpoint. Turn on **Management permissions** for the key — at creation
time or later — otherwise the request is answered with `403 insufficient_scope`. CodexBar reports that
case as a permissions problem and names this step, because the key itself is perfectly valid.

A management key (`ak_…`) and a signed-in dashboard session are also accepted by the endpoint. This
provider only ever sends the `sk-ar-…` inference key you configure.

## What it reads

The bundled JavaScript plugin reads `GET https://anyrouter.dev/api/v1/credits` with bearer
authentication. It displays, from the documented payload:

- **Available balance** — `balance`, the total remaining credit
- **Plan credits** — `monthly_balance`, AnyRouter-issued credit, spent before top-ups
- **Top-up credits** — `topup_balance`, purchased credit, spent last and never expiring
- **Lifetime spend** — `used`, cumulative across every successful request
- **Spent today (UTC)** — `today_cost`, since the start of the current UTC day

All values are USD, and one credit is one US dollar, so a payload in any other currency is rejected
rather than relabelled. Zero and slightly negative balances are preserved; negative plan, top-up, and
spend accumulations are impossible and fail the refresh. Missing or malformed values fail the refresh;
they do not become zero. The shared HTTP host bounds requests and retries transient failures.

This endpoint reports no spending limit and no reset date, so the provider shows amounts without a
percentage bar, reset countdown, or billing-period estimate.

## What it deliberately does not do

The request is a single read of the credential holder's own balance. CodexBar does not send inference
traffic, create, edit, or delete keys, read or donate keys to AnyRouter's shared key pool, inspect the
model catalog, or read request logs. Every value shown comes from the one response above; no identity or
plan field is inferred from another provider.

Sources: [Credits API](https://docs.anyrouter.dev/api-reference/credits),
[Terms of Service](https://anyrouter.dev/terms), and [status](https://anyrouter.dev/health).
