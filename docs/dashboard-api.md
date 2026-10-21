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

Usage labels and bar widths follow the app's **Usage bars fill** preference through `host.usageBarsShowUsed`: `true`
shows used percentages; `false` shows remaining percentages. On macOS the server reads the preference for each request,
so changes apply without restarting `serve`. The default is remaining when no preference exists, including on Linux;
older browser-cached snapshots without this field also use remaining. Earlier web dashboards always showed used
percentages. The numeric `usedPercent` and `remainingPercent` fields retain their existing meanings.

The **Usage display** control defaults to **Follow server**. **Used** and **Remaining** override labels and bar widths
only in this browser, persisted under `codexbar.dashboard.usageDisplay` in localStorage. Choosing **Follow server**
removes the override. Unknown values or unavailable storage fall back to the server preference on load; if saving
fails, selections still work for the current page. Warning and critical levels always use consumption, regardless
of display mode. This preference does not change the API payload, identity policy, or provider data.
The same control works for Linux servers and older cached snapshots without a host fill hint or remaining percentage;
**Follow server** still defaults to remaining, deriving it from consumption when needed. The control adds no external assets.

The UI does not change the transport threat model: `codexbar serve` is plain HTTP. Off-loopback, a token typed into the page transits the network in cleartext like every other request unless a TLS-terminating reverse proxy protects the connection.

## One-shot command semantics

- `codexbar dashboard` reads enabled providers from CodexBar config, emits them in stable order, and carries configured
  ordering through each row's `display.sortKey`.
- Identity defaults to full account emails. Pass `--identity redacted` to hide email local parts. Provider failures stay
  in their rows without discarding healthy rows.
- `codexbar serve` differs on one point: without `--identity` it follows the app's "Hide personal information" setting
  per request, so the web UI matches the menu UI. `codexbar dashboard` always defaults to full identity.
- A valid full, partial, empty, or all-error snapshot exits `0`. Command-wide setup or encoding failure writes a
  diagnostic to stderr and exits non-zero without writing a substitute document to stdout.
- Stdout contains exactly one JSON document plus a trailing newline. `--pretty` changes formatting only;
  `--json-output` controls optional logs on stderr.
- `--timeout <seconds>` accepts `0...86400` and defaults to `30`; `0` disables the command deadline.
- The one-shot payload reports `host.refreshIntervalSeconds` as `0` because it has no response cache.
  `staleAfterSeconds` keeps the schema's 180-second minimum.
- Both transports include the fill preference in host metadata; one-shot snapshots resolve it when collected.

## Optional live multi-account snapshots

`codexbar serve --all-accounts` fetches visible Codex accounts/profile homes and configured token accounts into
`providers[].accounts[]`. Without this flag, managed Codex entries still come from saved metadata and usage as
specified below. One-shot `codexbar dashboard` keeps that saved-account behavior. Claude-swap remains authoritative
when enabled, including empty results and whole-adapter failures; unused Claude token accounts are not fetched.

Expanded snapshots default to no identity, neutral numbered account labels, and generic account/provider/adapter
errors, independently of the app privacy setting. This includes the selected provider row. `--identity full`
explicitly includes emails, aliases and error details. `--identity redacted` retains masked email domains and plan
labels, but keeps labels neutral and errors generic. Numbering follows discovery order; correlate accounts by ID.

Managed Codex IDs remain `codex-managed:<uuid>` in both modes and survive promotion to the live source. Token
accounts use persisted UUIDs. Other Codex IDs hash durable source metadata (normalized profile-home path or live
workspace ID); they never expose raw paths, emails, cache keys or credential fingerprints. Moving a profile home
changes its ID. An unmanaged live source without a workspace ID has a system-scope ID, not a person-specific ID.
These IDs are correlation handles, not an anonymity guarantee.

Each provider appears once; its top-level usage, identity, credits and error describe the selected account, with
first-discovered fallback only when no active account is identified. Account rows retain independent usage/errors;
a failed selected account is never replaced by a healthy sibling. Completed results survive a sibling reaching the
existing provider deadline. Unfinished accounts receive timeout errors without borrowing cached usage. More
accounts can take longer. Provider cost collection is unchanged and is not apportioned across accounts.

Unreadable inventory or missing configured token accounts produces the generic `Account list incomplete` warning
while retaining available rows. A represented failure or timeout is not missing inventory. Whole-adapter failure
omits `accounts`; a successful empty adapter response keeps `accounts: []`, with no token-account fallback.

The flag is startup-only, with separate response-cache keys and provider-operation fingerprints. Ordinary snapshots
keep their existing identity policy. `/usage` retains its existing Codex enumeration; `/cost`, authentication and
transport behavior are unchanged. No account creation, selection or credential-storage policy is added.

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
- The response bodies — plan labels, usage percentages, cost figures, and account emails — cross the network in cleartext too. On non-loopback binds, pass `--identity redacted` to hide email local parts unless clients need full identity. Pin the flag rather than relying on the app's privacy setting, which a later GUI change can flip back.
- Because non-loopback binds gate `/accounts`, `/accounts/<id>`, `/usage`, `/cost`, and `/dashboard/v1/snapshot` behind the same token, a passive observer sees your account data but an active client without the token gets `401` on every data route. Only the account-free static UI at `/` and `/health` are unauthenticated off-loopback.

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

   A non-loopback `--host` refuses to start without a token, and refuses to start without `--allow-plain-http` — passing that flag is the explicit, operational acceptance that cleartext bearer transport is fine on this network. Account emails are included in dashboard responses unless redacted, and an absent flag follows a GUI setting that can change, so pin `--identity redacted` for these deployments. The token gates all data routes, and the server logs a one-line warning at startup.

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

## Account discovery

`GET /accounts` returns a separate, metadata-only inventory. It includes configured provider token
accounts and saved managed Codex accounts, including disabled providers. It does not enumerate system
auth, profile homes, or external account integrations. `GET /accounts/<id>` returns exactly one list
entry. IDs are stable opaque strings scoped to their source and provider; clients must URL-encode
them and must not parse their format.

```json
{
  "schemaVersion": 1,
  "accounts": [
    {
      "id": "<opaque-id>",
      "provider": "codex",
      "source": "codex-managed",
      "label": "Example Workspace",
      "active": true,
      "identity": { "accountEmail": "user@example.com" }
    }
  ]
}
```

`source` is `codex-managed` or `token-account`. Token accounts omit `identity`; managed Codex accounts
can include `identity.accountEmail`. `active` reflects the configured selection within that provider
and source, not credential validity, provider enablement, or the system Codex account.
An empty inventory returns `accounts: []`; an unknown ID returns `404` with
`{"error":"account not found"}`. Unreadable or unsupported stores return a generic `500` error
without exposing paths or silently returning an incomplete inventory.

These endpoints share the non-loopback bearer gate used by `/usage` and `/cost`; authorization runs
before storage is read. All account responses, including errors, carry `Cache-Control: no-store`.
Each request reads current config and managed-account metadata without collecting usage, accessing
managed credential files, migrating storage, or changing selections. Tokens, cookies, private paths,
credential fingerprints, and provider-internal account/workspace identifiers are excluded.

The existing `--identity full|redacted` setting applies. With no flag, `serve` follows the app's
**Hide personal information** setting per request. Redacted discovery replaces all arbitrary labels
with generic account placeholders and email local parts with `redacted`, retaining email domains.
IDs stay the same in both modes. This inventory is separate from dashboard account rows, which may
also include saved usage and adapter errors.

## Serve semantics

Snapshot requests share the serve cache and coordination machinery used by `/usage` and `/cost`:

- Responses are cached for `--refresh-interval` seconds, keyed by the loaded provider config, so toggling providers does not require a restart.
- Dashboard response keys also include the resolved identity mode and usage-bar fill preference, preventing a cached
  response for the other mode from overriding current host metadata.
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

The snapshot is a stable display contract, not a raw dump of provider internals. Without `--all-accounts`, identity defaults to full account emails and plan labels. Pass `--identity redacted` to replace email local parts with `redacted` while keeping domains and plan labels. On `codexbar serve` an absent `--identity` follows the app's "Hide personal information" setting instead of the full default.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-16T12:00:00Z",
  "staleAfterSeconds": 180,
  "host": {
    "codexBarVersion": "0.37.2",
    "refreshIntervalSeconds": 60,
    "usageBarsShowUsed": false
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

When the claude-swap integration is enabled, the Claude provider row additionally includes an `accounts` array. This
is an additive schema-v1 extension: other provider rows and Claude rows without the integration keep their existing
shape. An account's `label` preserves its alias or disambiguated email/organization label, falling back to its slot label. The web dashboard prefers this projected label over the raw identity email; `identity` is present
whenever claude-swap reports an email, independently of whether that account's usage fetch succeeds. Both fields follow
the dashboard identity mode: full by default, or redacted with `--identity redacted`.
When managed Codex accounts exist, the Codex row uses the same array on both `codexbar dashboard` and
`GET /dashboard/v1/snapshot`. Entries follow the managed account store's order and have stable
`codex-managed:<uuid>` IDs, independent of email, workspace labels, and the current selection. `active` identifies
the managed account selected in CodexBar config; system and profile-home selections leave all managed entries inactive.
The ambient Codex row remains available separately.

Codex account windows, pace, plan, and `updatedAt` come from the app's last saved account usage, matched to the
managed UUID, email, and selected workspace. This projection reads only account metadata and saved usage: it does
not read credentials, refresh accounts, or switch authentication. Missing or mismatched usage leaves the account
visible with empty windows, null pace/update time, and an account-local diagnostic. Saved refresh failures use a
fixed diagnostic instead of exporting raw errors that may contain private paths. Refresh the account in CodexBar
to update its saved usage. No managed accounts means no `accounts` field. The shared identity mode applies to every
account email and label, including email addresses embedded in workspace labels.

A failure limited to one account stays in that account's `error`; a failure of the whole adapter sets `accountsError`
while leaving the ambient provider row intact.
The web dashboard retains local spend totals and the daily chart once per provider group, with provider diagnostics labeled separately. Account cards keep their own usage and errors; ambient account credits are not presented as shared balances.

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

A managed Codex entry in redacted mode (other account fields use the same shapes as above):

```json
{
  "id": "codex-managed:9e122a52-b3db-4a7e-a7a7-c3b8fc9d01e9",
  "label": "redacted@example.com — Work",
  "active": true,
  "identity": { "accountEmail": "redacted@example.com", "plan": "Plus" },
  "windows": [{ "kind": "session", "label": "Session", "usedPercent": 40, "remainingPercent": 60, "resetAt": "2026-10-04T17:00:00Z" }],
  "pace": null,
  "error": null,
  "updatedAt": "2026-10-04T12:00:00Z"
}
```

## Fields

- `schemaVersion`: Dashboard API schema version.
- `generatedAt`: Snapshot generation timestamp.
- `staleAfterSeconds`: Client-side staleness hint.
- `host.codexBarVersion`: CodexBar version when available.
- `host.refreshIntervalSeconds`: HTTP response cache interval, or `0` for the one-shot command.
- `host.usageBarsShowUsed`: Display hint for usage labels and bar widths (`true`: used; `false`: remaining). Defaults
  to false when the app preference is absent. This is an additive schema-v1 field; raw quota percentages do not change.
- `providers[].id`: Provider identifier.
- `providers[].name`: Provider display name.
- `providers[].enabled`: Whether the provider is enabled in CodexBar config.
- `providers[].source`: Source used for the provider data.
- `providers[].status`: Provider service status when available (`level`: `ok` | `warning` | `critical` | `unknown`).
- `providers[].identity`: Account email and plan label, or `null`; the email local part is hidden only in redacted mode.
- `providers[].windows`: Session, weekly, tertiary, or provider-specific rate windows. Antigravity drops its
  duplicated representative rows here and emits one row per quota bucket instead.
- `providers[].windows[].idle`: `true` when a display client should skip the row, because the window belongs to a
  model family that reports no usage. The key appears only when it is `true`, so a payload with no idle window keeps
  its previous shape. This is an additive schema-v1 extension. A client that wants every window, such as a script or
  an adapter, ignores the key and keeps the row. The built-in web UI drops these rows so the page matches the app
  menu, which hides an untouched Antigravity model family. Only the producer can set this: a zero `usedPercent` also
  stands for a lane whose usage the provider never reported, and the payload does not carry that distinction.
- `providers[].credits`: Remaining credits or balance when available.
  Grok's purchased wallet is currently exposed by `codexbar usage --provider grok --json` and `/usage` as
  `usage.providerCost.balance` with `currencyCode: "USD"`, not by this dashboard projection. It is separate from
  the included quota: zero is a known balance, absence is unknown, and balance-only `used`/`limit` values of zero
  do not establish spend or a budget. See [Grok](grok.md#purchased-credits-in-cli-json).
- `providers[].cost`: Local cost data when available, otherwise a provider's reported 30-day USD history.
  Reported history preserves its aggregate, including a known zero, and leaves `todayUSD` null because its day
  boundaries may differ from the host's local calendar. OpenRouter Activity covers completed UTC days; it must
  not become local "Today" merely because a daily date string matches. Unsupported currencies or history-window
  lengths remain unavailable in these USD/30-day fields. Existing local cost rows retain precedence.
- `providers[].display`: UI hints for ordering and coloring.
- `providers[].error`: Provider error payload when the latest fetch failed.
- `providers[].updatedAt`: Best-known update timestamp for the provider row.
- `providers[].accounts`: Ordered local multi-account entries when an integration supplies them; an enabled claude-swap source
  with no accounts emits `[]`; Codex omits the field when no managed accounts exist.
  - `id`: Stable source and slot identifier, such as `claude-swap:2` or `codex-managed:<uuid>`.
  - `label`: Projected alias or disambiguated email/organization label, otherwise a slot label such as `Account 2`; follows the dashboard identity mode and is preferred for display over `identity.accountEmail`.
  - `active`: Whether this is the source's active account.
  - `identity`: Account email even when usage is unavailable; otherwise `null`. Claude-swap has a `null` plan;
    Codex includes the saved plan when available. The email local part is hidden only in redacted mode.
  - `windows`: Account-local session, weekly, and scoped windows in the same shape as `providers[].windows`.
  - `pace`: Account-local primary, secondary, and tertiary pace values when computable. Each pace value contains
    `stage`, `deltaPercent`, `expectedUsedPercent`, `willLastToReset`, `etaSeconds`, `runOutProbability`, and `summary`.
  - `error`: Account-local diagnostic, or `null`.
  - `updatedAt`: Account snapshot update timestamp, or `null`.
- `providers[].accountsError`: Whole-adapter diagnostic when account collection fails; `accounts` is then absent and
  the ambient provider data remains available.
