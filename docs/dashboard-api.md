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

The browser keeps the last successfully merged snapshot in localStorage under `codexbar.lastSnapshot` and paints that data immediately on the next load, preserving the identity detail served by the configured mode. It then fetches the config-only shell and streams concurrent per-provider snapshot updates into the page as they finish. Signing out clears both the token and cached snapshot.

The UI does not change the transport threat model: `codexbar serve` is plain HTTP. Off-loopback, a token typed into the page transits the network in cleartext like every other request unless a TLS-terminating reverse proxy protects the connection.

## One-shot command semantics

- `codexbar dashboard` reads enabled providers from CodexBar config, emits them in stable order, and carries configured
  ordering through each row's `display.sortKey`.
- Identity defaults to full account emails. Pass `--identity redacted` to hide email local parts. Provider failures stay
  in their rows without discarding healthy rows.
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
- The response bodies — plan labels, usage percentages, cost figures, and full account emails by default — cross the network in cleartext too. On non-loopback binds, use `--identity redacted` to hide email local parts unless clients need full identity.
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
   CODEXBAR_DASHBOARD_TOKEN=... codexbar serve --host 0.0.0.0 --allow-plain-http --identity redacted
   ```

   A non-loopback `--host` refuses to start without a token, and refuses to start without `--allow-plain-http` — passing that flag is the explicit, operational acceptance that cleartext bearer transport is fine on this network. Full account emails are included in dashboard responses by default, so `--identity redacted` is recommended for these deployments. The token gates all data routes, and the server logs a one-line warning at startup.

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
- Slow builds keep running past the request deadline; the finished result is committed to the response cache and handed to any same-config request already waiting, so a 504 first load self-heals on retry (the built-in web UI retries automatically).
- Authorization is checked before the cache, so unauthenticated requests can neither warm nor read it.

### Snapshot query parameters

- `provider=<id>` returns a snapshot containing only the selected provider row. Provider names are validated like `/usage`; unknown providers return `400` with the normal JSON error shape.
- `detail=full` is the default and returns the complete snapshot. `detail=shell` returns schema-v1 host metadata plus config-derived provider rows containing only `id`, `name`, `enabled`, and `display`; it performs no provider fetches or cost scans. Other detail values return `400`.
- `detail=shell&provider=<id>` is supported and returns the config-only shell for that provider.

### Stale responses and background refresh

After a fresh cache entry expires, `codexbar serve` may answer immediately with its last-good response while rebuilding that same route and configuration in the background. Concurrent refresh triggers still coalesce, and a slow rebuild commits even if it outlives the initiating request deadline. Clients can use `generatedAt` together with `staleAfterSeconds` to decide how to present freshness. This behavior is disabled when `--refresh-interval 0`.

## Payload

The snapshot is a stable display contract, not a raw dump of provider internals. Identity defaults to full account emails and plan labels. Pass `--identity redacted` to replace email local parts with `redacted` while keeping domains and plan labels.

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
        "accountEmail": "user@example.com",
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

### Multi-account providers

When a provider has multiple configured token accounts, its provider row additionally includes an `accounts` array
using the same account order and active selection as the app. Codex uses its reconciled visible accounts, including
managed and profile-home accounts. A single-account provider keeps the previous shape without `accounts`.

The opt-in claude-swap integration remains Claude's preferred account source when enabled. Its account `label` is the
email when known and otherwise falls back to its slot label; `identity` is present whenever claude-swap reports an
email, independently of whether that account's usage fetch succeeds. Account labels and identity follow the dashboard
identity mode: full by default, or redacted with `--identity redacted`.

A failure limited to one account stays in that account's `error`. A failure of the whole account collection sets
`accountsError` while preserving the provider row and any account results already collected.

```json
{
  "id": "claude",
  "identity": { "accountEmail": "user@example.com", "plan": "Max" },
  "windows": [{ "kind": "session", "label": "Session", "usedPercent": 20, "remainingPercent": 80, "resetAt": "2026-07-16T17:00:00Z" }],
  "accounts": [
    {
      "id": "claude-swap:2",
      "label": "personal@personal.example",
      "active": true,
      "identity": { "accountEmail": "personal@personal.example", "plan": null },
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
      "label": "expired@example.com",
      "active": false,
      "identity": { "accountEmail": "expired@example.com", "plan": null },
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
- `providers[].identity`: Account email and plan label, or `null`; the email local part is hidden only in redacted mode.
- `providers[].windows`: Session, weekly, tertiary, or provider-specific rate windows.
- `providers[].credits`: Remaining credits or balance when available.
- `providers[].cost`: Local cost data when available.
- `providers[].display`: UI hints for ordering and coloring.
- `providers[].error`: Provider error payload when the latest fetch failed.
- `providers[].updatedAt`: Best-known update timestamp for the provider row.
- `providers[].accounts`: Ordered local multi-account entries. The field is absent for single-account providers; an
  enabled claude-swap source with no accounts emits `[]`.
  - `id`: Stable opaque account identifier. Claude-swap retains its source and slot form, such as `claude-swap:2`.
  - `label`: Account email when known, otherwise a slot label such as `Account 2`; email labels follow the dashboard
    identity mode.
  - `active`: Whether this is the source's active account.
  - `identity`: Account email and plan when available, or `null`. Claude-swap reports a `null` plan. The email local
    part is hidden only in redacted mode.
  - `windows`: Account-local session, weekly, and scoped windows in the same shape as `providers[].windows`.
  - `pace`: Account-local primary, secondary, and tertiary pace values when computable. Each pace value contains
    `stage`, `deltaPercent`, `expectedUsedPercent`, `willLastToReset`, `etaSeconds`, `runOutProbability`, and `summary`.
  - `error`: Account-local diagnostic, or `null`.
  - `updatedAt`: Account snapshot update timestamp, or `null`.
- `providers[].accountsError`: Account-collection diagnostic when the full configured account set cannot be projected;
  provider data and any collected account rows remain available.
