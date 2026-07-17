---
summary: "Dashboard snapshot API for codexbar serve: bearer-token auth, plain-HTTP threat model, and the display-oriented payload contract."
read_when:
  - "Building a dashboard client against codexbar serve"
  - "Configuring --dashboard-token, --host, or --allow-plain-http"
  - "Reviewing the serve auth or transport security model"
---

# Dashboard Snapshot API

`codexbar serve` exposes a versioned, display-oriented snapshot of CodexBar usage data for dashboard clients:

```text
GET /dashboard/v1/snapshot
Authorization: Bearer YOUR_TOKEN
```

The route is gated by a static bearer token and **fails closed**: without a configured token every request answers `401`. The token is only ever read from the `Authorization` header — a query-string parameter named `token` is never accepted. Every response on the dashboard route — including all `401`s and error responses — carries `Cache-Control: no-store`.

On the default loopback bind, `/usage` and `/cost` are unchanged and unauthenticated. On a **non-loopback** bind the same token gates **all data routes**: `/usage`, `/cost`, and `/dashboard/v1/snapshot` each require `Authorization: Bearer YOUR_TOKEN`, so account data never leaves the machine unauthenticated. `/health` is always open (it carries only a status and version string, useful for liveness probes).

## Configuring the token

```bash
# Generate a strong token
openssl rand -hex 32

# Preferred: environment variable (argv leaks via `ps`)
CODEXBAR_DASHBOARD_TOKEN=YOUR_TOKEN codexbar serve

# Also accepted, but visible in the process list
codexbar serve --dashboard-token YOUR_TOKEN
```

- `CODEXBAR_DASHBOARD_TOKEN` wins over `--dashboard-token` when both are set.
- Empty or whitespace-only tokens are startup errors, not a silent no-auth mode.
- Rotate the token by restarting `serve` with a new value.
- `--host` accepts `localhost` or an IPv4 address; the socket layer does not support IPv6 binds.

## Threat model — read before binding beyond loopback

Transport is **plain HTTP**. There is no TLS in `codexbar serve`, which means:

- The bearer token crosses the network **in cleartext on every request**. Anyone who can observe the path (same Wi-Fi, ARP spoofing, a compromised switch, your ISP on a routed path) can capture the token and replay it until the server restarts with a new one.
- The response bodies — plan labels, usage percentages, email domains, cost figures — cross the network in cleartext too.
- Because non-loopback binds gate `/usage`, `/cost`, and `/dashboard/v1/snapshot` behind the same token, a passive observer sees your account data but an active client without the token gets `401` on every data route. `/health` is the only unauthenticated route off-loopback.

Deployments, from safest to least safe:

1. **Loopback only (default).** `codexbar serve` binds `127.0.0.1`; nothing leaves the machine. Rejects non-loopback `Host` headers, so browser-based DNS-rebinding attacks cannot reach it either.
2. **TLS-terminating reverse proxy.** Keep the loopback bind and put a proxy in front. Caddy example:

   ```caddyfile
   dashboard.example.com {
       handle /dashboard/v1/* {
           reverse_proxy 127.0.0.1:8080 {
               header_up Host 127.0.0.1
           }
       }
       respond 404
   }
   ```

   Caddy provisions certificates automatically. The route matcher exposes only the authenticated dashboard API, while the upstream `Host` rewrite satisfies the loopback server's rebinding check. The token travels inside TLS from the client to the proxy and only crosses the loopback interface in cleartext.
3. **Trusted network segment, cleartext accepted.** Bind a LAN address directly:

   ```bash
   CODEXBAR_DASHBOARD_TOKEN=... codexbar serve --host 0.0.0.0 --allow-plain-http
   ```

   A non-loopback `--host` refuses to start without a token, and refuses to start without `--allow-plain-http` — passing that flag is the explicit, operational acceptance that cleartext bearer transport is fine on this network. The token then gates all data routes, and the server logs a one-line warning at startup.

The server compares tokens in constant time (fixed-length SHA-256 digest comparison), so timing does not leak a matching prefix. That protects the comparison, not the transport: on plain HTTP the token is still readable in transit.

## Auth failures

Missing, malformed, or wrong credentials produce:

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Cache-Control: no-store
Content-Type: application/json; charset=utf-8

{"error":"unauthorized"}
```

## Serve semantics

Snapshot requests share the serve cache and coordination machinery used by `/usage` and `/cost`:

- Responses are cached for `--refresh-interval` seconds, keyed by the loaded provider config, so toggling providers does not require a restart.
- Concurrent cache misses coalesce into one fetch; `--request-timeout` bounds each request with `504 Gateway Timeout`.
- Authorization is checked before the cache, so unauthenticated requests can neither warm nor read it.

## Payload

The snapshot is a stable display contract, not a raw dump of provider internals. Identity is always redacted: email local parts are hidden while domains and plan labels are kept.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-16T12:00:00Z",
  "staleAfterSeconds": 180,
  "host": {
    "codexBarVersion": "0.37.2",
    "refreshIntervalSeconds": 60
  },
  "providers": [
    {
      "id": "codex",
      "name": "Codex",
      "enabled": true,
      "source": "oauth",
      "status": {
        "level": "ok",
        "label": "Operational",
        "updatedAt": "2026-07-16T11:59:00Z"
      },
      "identity": {
        "accountEmail": "redacted@example.com",
        "plan": "Pro 20x"
      },
      "windows": [
        {
          "kind": "session",
          "label": "Session",
          "usedPercent": 28,
          "remainingPercent": 72,
          "resetAt": "2026-07-16T17:15:00Z"
        }
      ],
      "credits": {
        "remaining": 112.4,
        "unit": "credits"
      },
      "cost": {
        "todayUSD": 1.04,
        "last30DaysUSD": 18.22
      },
      "display": {
        "accentColor": "#49A3B0",
        "sortKey": 0,
        "priority": "normal"
      },
      "error": null,
      "updatedAt": "2026-07-16T11:59:45Z"
    }
  ]
}
```

## Fields

- `schemaVersion`: Dashboard API schema version.
- `generatedAt`: Snapshot generation timestamp.
- `staleAfterSeconds`: Client-side staleness hint.
- `host.codexBarVersion`: CodexBar version when available.
- `host.refreshIntervalSeconds`: Server response cache interval.
- `providers[].id`: Provider identifier.
- `providers[].name`: Provider display name.
- `providers[].enabled`: Whether the provider is enabled in CodexBar config.
- `providers[].source`: Source used for the provider data.
- `providers[].status`: Provider service status when available (`level`: `ok` | `warning` | `critical` | `unknown`).
- `providers[].identity`: Redacted account email and plan label, or `null`.
- `providers[].windows`: Session, weekly, tertiary, or provider-specific rate windows.
- `providers[].credits`: Remaining credits or balance when available.
- `providers[].cost`: Local cost data when available.
- `providers[].display`: UI hints for ordering and coloring.
- `providers[].error`: Provider error payload when the latest fetch failed.
- `providers[].updatedAt`: Best-known update timestamp for the provider row.
