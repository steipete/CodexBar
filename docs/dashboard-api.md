# Dashboard Snapshot API

`codexbar serve` exposes a versioned dashboard snapshot for clients that need a compact, display-oriented view of CodexBar usage data.

```text
GET /dashboard/v1/snapshot
```

The endpoint is available from the foreground HTTP server started by `codexbar serve`. The default bind host remains `127.0.0.1`. Serving on a non-loopback host requires `--dashboard-token`, and data routes require `Authorization: Bearer YOUR_TOKEN` when a token is configured. `/health` remains unauthenticated.

Identity exposure is controlled with:

```text
--dashboard-identity none|redacted|full
```

The default is `redacted`.

Identity modes:

- `none`: omit the `identity` object entirely.
- `redacted`: include non-secret plan labels and redact account email local parts while preserving domains, for example `redacted@example.com`. Addresses without a domain become `redacted`.
- `full`: include the full account email and plan label.

## Payload

The snapshot is a stable display contract, not a raw dump of provider internals.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-05-16T12:00:00Z",
  "staleAfterSeconds": 180,
  "host": {
    "codexBarVersion": "0.17.0",
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
        "updatedAt": "2026-05-16T11:59:00Z"
      },
      "identity": {
        "accountEmail": "redacted@example.com",
        "plan": "Plus"
      },
      "windows": [
        {
          "kind": "session",
          "label": "Session",
          "usedPercent": 28,
          "remainingPercent": 72,
          "resetAt": "2026-05-16T17:15:00Z"
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
        "accentColor": "#6E5AFF",
        "sortKey": 10,
        "priority": "normal"
      },
      "error": null,
      "updatedAt": "2026-05-16T11:59:45Z"
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
- `providers[].status`: Provider service status when available.
- `providers[].identity`: Account and plan identity according to the configured identity mode.
- `providers[].windows`: Session, weekly, tertiary, or provider-specific rate windows.
- `providers[].credits`: Remaining credits or balance when available.
- `providers[].cost`: Local cost data when available.
- `providers[].display`: UI hints for ordering and coloring.
- `providers[].error`: Provider error payload when the latest fetch failed.
- `providers[].updatedAt`: Best-known update timestamp for the provider row.
