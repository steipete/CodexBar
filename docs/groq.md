---
summary: "Groq provider: console spend/usage via the browser session (Stytch), with an optional Enterprise Prometheus fallback."
read_when:
  - Updating Groq usage/spend display
  - Debugging Groq console session, Stytch refresh, or GROQ_API_KEY behavior
---

# Groq provider

CodexBar shows Groq organization usage and spend from the **console.groq.com** dashboard API, read through your
browser session. This replaces the old public-API rate-limit metric, which only described request/token throttles
rather than actual usage.

## Data sources + selection order

Default (`auto`) pipeline:

1. **Console (web, preferred).** Reads the console session cookie from the browser and calls the platform activity
   API for daily spend/token/request history.
2. **Prometheus metrics (Enterprise API key, fallback).** Only used when a session isn't available and an API key is
   configured; Enterprise-only, so standard keys return no data here.

Source modes: `web` (console only), `api` (Prometheus only), `auto` (console then Prometheus).

## Console (web)

- Session comes from the `groq.com` cookies, in browser import order:
  - `stytch_session` — long-lived (~30 day) opaque token. Preferred.
  - `stytch_session_jwt` — short-lived (~5 min) JWT. Used directly only as a fallback.
- Because the JWT cookie expires quickly and is refreshed by the SPA only while a console tab is open, CodexBar
  exchanges the long-lived opaque token for a fresh JWT on each fetch via Stytch's B2B frontend SDK endpoint (the same
  call the console web app makes):
  - `POST https://api.stytchb2b.groq.com/sdk/v1/b2b/sessions/authenticate`
  - Auth: `Authorization: Basic base64(<publicToken>:<sessionToken>)`, plus `X-SDK-Client`, `X-SDK-Parent-Host`, and
    `Origin: https://console.groq.com` headers.
  - The publishable Stytch token is built in; override with `GROQ_STYTCH_PUBLIC_TOKEN` / `GROQ_STYTCH_URL` if Groq
    rotates it.
- Usage/spend:
  - `GET https://api.groq.com/platform/v1/organizations/{orgId}/activity?start_date={unix}&end_date={unix}`
  - `Authorization: Bearer <fresh session JWT>`.
  - The organization id is read from the JWT's `https://groq.com/organization` claim (no signature verification —
    the API authenticates the token, this only reads the routing claim).
- Each activity row is per-model, per-day: `cost`, `n_context_tokens_total`, `n_non_cached_context_tokens_total`
  (cached = context − non-cached), `n_generated_tokens_total`, `num_requests`. CodexBar aggregates these into daily
  buckets and renders the shared cost-history inline dashboard (as used by the OpenAI API provider).
- Identity login method: `Console`.

### Testing / CLI overrides

- `GROQ_SESSION_TOKEN` — an opaque `stytch_session` value; exercises the full refresh path.
- `GROQ_SESSION_JWT` — a session JWT used directly (skips refresh); handy for a quick check but expires in minutes.

```bash
GROQ_SESSION_TOKEN=<stytch_session> codexbar usage --provider groq --json
```

## Prometheus metrics (Enterprise, optional)

- Requires an Enterprise API key stored in `~/.codexbar/config.json` (Settings → Providers → Groq) or `GROQ_API_KEY`.
- `GET https://api.groq.com/v1/metrics/prometheus/api/v1/query` for `rate5m` request/token/cache series.
- Standard keys receive HTTP 404 here (Enterprise-only feature), so this path simply yields no data for them.

## Key files

- Console fetch: `Sources/CodexBarCore/Providers/Groq/GroqConsoleFetcher.swift`
- Session import + JWT resolution: `Sources/CodexBarCore/Providers/Groq/GroqConsoleSession.swift`
- Stytch refresh: `Sources/CodexBarCore/Providers/Groq/GroqConsoleStytch.swift`
- Snapshot / cost-history projection: `Sources/CodexBarCore/Providers/Groq/GroqConsoleUsageSnapshot.swift`
- Prometheus fallback: `Sources/CodexBarCore/Providers/Groq/GroqUsageFetcher.swift`
- Provider wiring: `Sources/CodexBarCore/Providers/Groq/GroqProviderDescriptor.swift`
