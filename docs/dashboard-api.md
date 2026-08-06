---
summary: "Dashboard-v1 snapshot contract for one-shot CLI and HTTP clients, including serve auth and transport."
read_when:
  - "Building a dashboard or adapter against CodexBar"
  - "Using codexbar dashboard from scripts"
  - "Configuring --dashboard-token, --host, or --allow-plain-http"
  - "Reviewing the serve auth or transport security model"
---

# Dashboard v1 Snapshot

CodexBar exposes one versioned, display-oriented snapshot contract through two transports:

```bash
# One JSON document on stdout, then exit
codexbar dashboard
```

```text
# Long-running HTTP endpoint
GET /dashboard/v1/snapshot
Authorization: Bearer YOUR_TOKEN
```

Both transports use the same producer and schema-v1 payload. The one-shot command starts no server and needs no token.

The HTTP route is gated by a static bearer token and **fails closed**: without a configured token every request answers `401`. The token is only ever read from the `Authorization` header — a query-string parameter named `token` is never accepted. Every response on the dashboard route — including all `401`s and error responses — carries `Cache-Control: no-store`.

On the default loopback bind, `/usage` and `/cost` are unchanged and unauthenticated. On a **non-loopback** bind the same token gates **all data routes**: `/usage`, `/cost`, and `/dashboard/v1/snapshot` each require `Authorization: Bearer YOUR_TOKEN`, so account data never leaves the machine unauthenticated. `/` and `/health` are always open; neither response contains account data.

## Built-in web UI

`GET /` serves a self-contained web dashboard that polls `/dashboard/v1/snapshot`. The static HTML is always unauthenticated, including on non-loopback binds, because it contains no account data. When the snapshot route returns `401`, the page asks for the dashboard token, stores it in the browser under the localStorage key `codexbar.dashboardToken`, and sends it in the `Authorization` header on each snapshot request. The token is never added to the URL.

The UI does not change the transport threat model: `codexbar serve` is plain HTTP. Off-loopback, a token typed into the page transits the network in cleartext like every other request unless a TLS-terminating reverse proxy protects the connection.

## One-shot command semantics

- `codexbar dashboard` reads enabled providers from CodexBar config, emits them in stable order, and carries configured
  ordering through each row's `display.sortKey`.
- Identity is always redacted. Provider failures stay in their rows without discarding healthy rows.
- A valid full, partial, empty, or all-error snapshot exits `0`. Command-wide setup or encoding failure writes a
  diagnostic to stderr and exits non-zero without writing a substitute document to stdout.
- Stdout contains exactly one JSON document plus a trailing newline. `--pretty` changes formatting only;
  `--json-output` controls optional logs on stderr.
- `--timeout <seconds>` accepts `0...86400` and defaults to `30`; `0` disables the command deadline.
- The one-shot payload reports `host.refreshIntervalSeconds` as `0` because it has no response cache.
  `staleAfterSeconds` keeps the schema's 180-second minimum.

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
- Because non-loopback binds gate `/usage`, `/cost`, and `/dashboard/v1/snapshot` behind the same token, a passive observer sees your account data but an active client without the token gets `401` on every data route. Only the account-free static UI at `/` and `/health` are unauthenticated off-loopback.

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

### Multi-account providers (claude-swap)

When the claude-swap integration is enabled, the Claude provider row additionally includes an `accounts` array. This
is an additive schema-v1 extension: other provider rows and Claude rows without the integration keep their existing
shape. Account identity follows the dashboard's always-redacted policy. A failure limited to one account stays in that
account's `error`; a failure of the whole adapter sets `accountsError` while leaving the ambient Claude row intact.

```json
{
  "id": "claude",
  "identity": { "accountEmail": "redacted@example.com", "plan": "Max" },
  "windows": [{ "kind": "session", "label": "Session", "usedPercent": 20, "remainingPercent": 80, "resetAt": "2026-07-16T17:00:00Z" }],
  "accounts": [
    {
      "id": "claude-swap:2",
      "label": "Account 2",
      "active": true,
      "identity": { "accountEmail": "redacted@personal.example", "plan": null },
      "windows": [
        { "kind": "session", "label": "Session", "usedPercent": 40, "remainingPercent": 60, "resetAt": "2026-07-16T17:00:00Z" },
        { "kind": "weekly", "label": "Weekly", "usedPercent": 60, "remainingPercent": 40, "resetAt": "2026-07-18T12:00:00Z" },
        { "kind": "claude-weekly-scoped-fable", "label": "Fable only", "usedPercent": 33, "remainingPercent": 67, "resetAt": "2026-07-18T12:00:00Z" }
      ],
      "pace": {
        "primary": { "stage": "ahead", "deltaPercent": 20, "expectedUsedPercent": 20, "willLastToReset": true, "etaSeconds": null, "runOutProbability": null, "summary": "20% in deficit | Expected 20% used | Lasts to reset" },
        "secondary": { "stage": "ahead", "deltaPercent": 31, "expectedUsedPercent": 29, "willLastToReset": false, "etaSeconds": 144000, "runOutProbability": null, "summary": "31% in deficit | Expected 29% used | Runs out in 1d 16h" }
      },
      "error": null,
      "updatedAt": "2026-07-16T12:00:00Z"
    },
    {
      "id": "claude-swap:1",
      "label": "Account 1",
      "active": false,
      "identity": null,
      "windows": [],
      "pace": null,
      "error": "Token expired. Switch to this account in claude-swap to refresh it.",
      "updatedAt": null
    }
  ]
}
```

## Fields

- `schemaVersion`: Dashboard API schema version.
- `generatedAt`: Snapshot generation timestamp.
- `staleAfterSeconds`: Client-side staleness hint.
- `host.codexBarVersion`: CodexBar version when available.
- `host.refreshIntervalSeconds`: HTTP response cache interval, or `0` for the one-shot command.
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
- `providers[].accounts`: Ordered local multi-account entries when an integration supplies them; an enabled source
  with no accounts emits `[]`.
  - `id`: Stable source and slot identifier, such as `claude-swap:2`.
  - `label`: Stable, non-sensitive display key, such as `Account 2`.
  - `active`: Whether this is the source's active account.
  - `identity`: Dashboard-redacted account email with a `null` plan, or `null`.
  - `windows`: Account-local session, weekly, and scoped windows in the same shape as `providers[].windows`.
  - `pace`: Account-local primary, secondary, and tertiary pace values when computable. Each pace value contains
    `stage`, `deltaPercent`, `expectedUsedPercent`, `willLastToReset`, `etaSeconds`, `runOutProbability`, and `summary`.
  - `error`: Account-local diagnostic, or `null`.
  - `updatedAt`: Account snapshot update timestamp, or `null`.
- `providers[].accountsError`: Whole-adapter diagnostic when account collection fails; `accounts` is then absent and
  the ambient provider data remains available.
