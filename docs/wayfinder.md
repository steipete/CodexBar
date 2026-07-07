---
summary: "Wayfinder setup for local gateway health, per-route breakdown, and savings."
read_when:
  - Configuring Wayfinder usage tracking
  - Debugging Wayfinder gateway health or savings display
  - Explaining the Wayfinder gateway URL setting
---

# Wayfinder

[Wayfinder](https://github.com/itsthelore/wayfinder-router) is a self-hosted, deterministic
local/cloud LLM router. Its gateway runs on the user's machine (default
`http://127.0.0.1:8088`) and scores each prompt offline — no model call — to decide whether
the cheap/local or the dearer/cloud tier serves it. CodexBar polls the gateway's read-only
JSON endpoints and shows whether the gateway is up, how traffic split across the configured
routes, what that saved versus routing everything to the dearest tier, and the average routing
decision time.

The integration is read-only. CodexBar never sends prompts through the gateway, never calls
its chat endpoints, and the endpoints it polls return accounting metadata only — Wayfinder's
API never exposes prompt text.

## Setup

Wayfinder's read-only endpoints are unauthenticated on loopback, so there is nothing to log
in to: enable the provider in CodexBar Settings → Providers → Wayfinder. The default gateway
URL is used unless you override it:

```text
http://127.0.0.1:8088
```

If your gateway listens elsewhere, set the Gateway URL in Settings or export
`WAYFINDER_GATEWAY_URL`. Overrides must be HTTPS, or plain HTTP for loopback addresses only
(`localhost`, `127.0.0.0/8`, `::1`) — the gateway is a local service and remote plain-HTTP
endpoints are rejected.

## Display

- Gateway health: `ok` or `degraded` (with the number of models missing API keys), plus
  offline-mode and dry-run markers.
- Routing split over the last 30 days: requests per configured route (up to 5, by request
  count), using each route's own name from the Wayfinder config — the gateway has no field
  asserting which route is "local," so CodexBar never guesses.
- Savings over the last 30 days versus routing everything to the dearest tier, with the
  percentage. Dollar amounts appear only when the gateway config prices its models
  (`cost_per_1k`); unpriced gateways report a relative percentage only.
- Average routing decision time, parsed best-effort from the gateway's Prometheus
  `/metrics` endpoint. Decisions are computed offline, so this is typically well under a
  millisecond.

## Endpoints polled

| Endpoint | Purpose |
| --- | --- |
| `GET /healthz` | Gateway status, configured models, offline flag, missing keys. |
| `GET /router/models` | Configured model count and dry-run flag. |
| `GET /v1/savings?period=30d` | Requests, tokens, realized/baseline cost, savings, per-route split. |
| `GET /metrics` | Decision-latency histogram for the average routing time (best effort). |

## Environment variables

| Variable | Description |
| --- | --- |
| `WAYFINDER_GATEWAY_URL` | Optional gateway URL override (HTTPS, or loopback HTTP). |

If the gateway is not running, CodexBar reports that it could not be reached and suggests
starting it with `wayfinder-router serve`.
