---
summary: "Grok provider data sources: ACP JSON-RPC, CLI-proxy and grok.com billing fallbacks, OAuth credentials, and local session signals."
read_when:
  - Debugging Grok billing/usage parsing
  - Updating `grok agent stdio` JSON-RPC integration
  - Adjusting `~/.grok/auth.json` credential reading
---

# Grok provider

Grok uses xAI's official Grok Build CLI (`grok`, released 2026-05-14). Usage data is
fetched via the ACP JSON-RPC `x.ai/billing` extension method over `grok agent stdio`
when available, then via the Grok CLI billing REST API using the local login token.
The grok.com billing gRPC-web endpoint remains a best-effort fallback.

## Settings source picker

- **Auto**: Grok CLI, then SuperGrok OAuth CLI-proxy, then browser cookies, then bearer gRPC.
- **Grok CLI**: `grok agent stdio` only.
- **SuperGrok OAuth**: `~/.grok/auth.json` or a pasted bearer / `GROK_OAUTH_TOKEN`. CLI-proxy credits, then bearer gRPC. No cookies.
- **Browser cookies**: grok.com Cookie header / Chrome import only. No OAuth bearer.
- Token accounts classify at fetch time: bearer → OAuth, `Cookie:` / `name=value` → cookies, `xai-` management keys rejected.
- Selecting a SuperGrok token account remaps Auto to OAuth or Web so it cannot hit an empty `.oauth` pipeline.

## Data sources + fallback order

1) **`~/.grok/auth.json` (primary identity source)**
   - Reads `email`, `team_id`, `first_name`/`last_name`, plan-hint (`auth_mode`),
     and the optional `principal_type` for the identity row in the menu.
   - Team principals are recognized on the CLI and web billing paths. Until Grok
     exposes a supported team usage surface, CodexBar keeps the identity row and
     reports that team usage is unavailable instead of exposing the personal-team
     rejection verbatim.
2) **`grok agent stdio` ACP JSON-RPC** (best-effort, currently disabled in grok 0.1.210)
   - We spawn `grok agent stdio` and call `initialize` + `x.ai/billing` (no params).
   - **Known limitation:** in grok 0.1.210 the `x.ai/billing` extension method
     is only wired in the interactive TUI; the agent-stdio surface returns
     `-32601 Method not found`. Personal/unknown principals continue to the web
     fallback, while a team principal degrades to identity-only with an explicit
     unsupported-team-usage diagnostic. When xAI exposes billing on the agent
     protocol, no code change is required.
   - After a successful RPC billing result (or the identity-only team fallback),
     CodexBar still GETs `/v1/settings` for `subscription_tier_display` so the
     billed plan is not lost just because the CLI route succeeded first. The
     settings lookup is optional enrichment with a 2-second budget.
   - One non-obvious quirk: grok's ACP parser does not unescape `\/` in method
     names. `Foundation.JSONSerialization.data` defaults to escaping forward
     slashes, so payloads must be re-encoded with `\/` → `/` before being
     written to stdin or grok will silently drop them (12s client-side
     timeout instead of the expected error response).
3) **Grok CLI-proxy billing REST API** (primary web-path attempt)
   - When a non-expired `~/.grok/auth.json` token exists, GETs
     `https://cli-chat-proxy.grok.com/v1/billing?format=credits` with
     `Authorization: Bearer <token>`, `x-xai-token-auth: xai-grok-cli`, and
     `Accept: application/json`.
   - Reads `config.creditUsagePercent`, falling back to
     `onDemandUsed.val / onDemandCap.val * 100`. A parseable current period
     without either value represents unknown usage. The reset timestamp comes from
     `config.currentPeriod.end`, then `config.billingPeriodEnd`.
   - Unknown usage yields no rate window at all, and a successful strategy ends the
     fetch pipeline, so a period-only credits answer would otherwise hide the usage
     bar for plans whose payload never publishes `creditUsagePercent`. Before that
     answer is accepted, CodexBar retries the grok.com bearer gRPC path (step 4,
     still without cookies) and adopts its percent when it has one, keeping the
     credits period and plan metadata, with the proxy's authoritative reset taking
     precedence over a conflicting gRPC timestamp. When grok.com has no percent
     either, or the retry fails, usage stays unknown and the card reports an explicit
     unavailable-usage diagnostic.
     Two grok.com readings are adopted: a percentage it actually put on the wire,
     and an implicit zero from a complete protobuf response with a recognized weekly
     or monthly current period whose start and end contain the current time, and no
     percentage fields anywhere. The parser carries this classification separately
     from wire-published percentages; a bare inferred zero, historical-only period,
     or malformed response cannot replace unknown proxy usage. Proxy reset and plan
     metadata remain authoritative when the zero is adopted.
     Invalid protobuf field numbers and overflowing varints prevent that response
     from qualifying as complete. Only schema-declared messages are recursively
     decoded; valid unknown length-delimited fields are skipped as opaque data,
     so their contents cannot invalidate the response or invent usage/reset values.
     Grok's public web client also reads its omitted proto3 scalar as zero, and its
     [billing descriptor](https://cdn.grok.com/_next/static/chunks/32g78bk5hhe1q.js)
     declares `credit_usage_percent` as an implicit-presence float (checked
     September 1, 2026). The protocol cannot distinguish an exact zero from a
     withheld scalar; this bounded interpretation matches the web client for an
     active billing period. A missing proxy value alone remains unknown. The retry
     also runs under a 6-second budget, because period-only payloads recur on every
     refresh and a grok.com outage must not delay the credits answer already in hand.
   - Plan name does not come from the credits payload. After a successful
     auth-file or SuperGrok OAuth web billing result (CLI-proxy) or the team
     identity-only path, CodexBar GETs `https://cli-chat-proxy.grok.com/v1/settings`
     with the same bearer headers and reads `subscription_tier_display`
     (`SuperGrok Heavy` vs `SuperGrok`). Cookie mode does not call the proxy.
     If the proxy fails, OAuth retries the grok.com bearer gRPC path, still
     without cookies. Cookie/gRPC fallbacks are a different browser session and
     do not reuse the auth-file settings tier. The request uses a 2-second timeout
     and `BoundedTaskJoin`, so a stuck settings call cannot delay already-fetched
     usage by 15 seconds. Settings timeouts, request failures, and 200 responses
     that omit `subscription_tier_display` all drop the plan overlay and fall
     back to the OIDC SuperGrok label. There is no process-lifetime tier cache.
4) **grok.com billing gRPC-web fallback** (best-effort)
   - POSTs an empty gRPC-web protobuf request to
     `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`.
   - This endpoint now requires the browser-held Web Key Exchange (WKE) keypair.
     Cookie-only authentication can fail with gRPC status 16 and
     `no-credentials`; signing in through Chrome alone cannot provide that proof
     to CodexBar, so `grok login` is the recommended recovery path.
   - Uses grok.com browser session cookies. Successful cookie usage never inherits
     the auth-file account's identity or settings tier.
   - CodexBar imports Chrome only by default to avoid unrelated browser
     Keychain prompts.
   - Ordinary CLI/test runtime does not import browser cookies unless
     `CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT=1` is set. An explicit
     `codexbar cookie refresh --provider grok` also opts in for that refresh.
   - Validated sessions are stored in the Keychain-backed cookie cache and are
     reused first by later app and CLI fetches, so background work does not
     re-open the Chromium Keychain gate. The cached cookie is evicted only on
     authentication failures (HTTP 401/403 or gRPC auth statuses); a cached
     team-limited session keeps degrading to identity-only data.
   - Auto can try a separate bearer-only probe after browser sessions fail.
     Expired tokens are not sent. A team-usage rejection may still produce the
     documented identity-only fallback from captured, non-expired team credentials;
     this does not attach those credentials to successful cookie usage.
   - Parses the returned protobuf enough to recover used percent and
     reset timestamp, accepting both gRPC-web frames and the raw protobuf form
     returned by some successful requests. A current billing period with an
     omitted proto3 `credit_usage_percent` is treated as zero usage. The
     unknown-usage retry adopts only the validated active-period shape described
     above. This keeps billing visible when
     `grok agent stdio` returns `Method not found`.
5) **Local session signals** (informational fallback)
   - Walks `~/.grok/sessions/<encoded-cwd>/<session-id>/signals.json` files (last 30 days).
   - Aggregates `totalTokensBeforeCompaction`, `contextTokensUsed`, `modelsUsed`,
     and the most recent session timestamp.

## OAuth credentials

- File: `~/.grok/auth.json` (path overridable via `GROK_HOME`). This remains
  the preferred identity source when `grok login` has written a non-expired token.
- Top-level keys are OIDC scope URLs. CodexBar prefers entries under
  `https://auth.x.ai::<client-id>` (SuperGrok), falling back to
  `https://accounts.x.ai/sign-in` (legacy session).
- Required fields per entry: `key` (bearer token), `refresh_token`, `expires_at`,
  `auth_mode`, `email`, `team_id`, `user_id`, `first_name`/`last_name`.
  `principal_type` is optional because older auth files do not include it.
- Tokens are issued by `grok login` and expire after ~7 days; refresh is handled by
  the CLI itself (CodexBar does not refresh; it just reads the cached credential).
- If `auth.json` is missing or expired, paste a SuperGrok bearer into Grok token
  accounts or set `GROK_OAUTH_TOKEN`. Cookie-shaped values and `xai-` management
  keys are rejected. The pasted token uses the same CLI-proxy credits URL.
- Settings also expose a cookie source (Auto / Manual / Off). Manual accepts a
  grok.com Cookie header when Chrome Safe Storage is denied. Auto still imports
  Chrome only.
- Credits `subscriptionTier` maps SuperGrok vs SuperGrok Heavy on the plan badge.
  SuperGrok Heavy with no `creditUsagePercent` is unknown usage from that payload,
  not 0%; the grok.com retry above can still supply a percent, including its
  no-usage-yet zero.
- Each OAuth fetch captures credentials once for billing, bearer retries, identity,
  and settings enrichment. Replacing `auth.json` during an awaited request cannot
  relabel the result with the new account. Cookie usage stays separate from this
  captured account; local session scanning and CLI behavior are unchanged.


## JSON-RPC contract

- Transport: stdin/stdout, newline-delimited JSON-RPC 2.0 (no Content-Length framing).
- `initialize` params:
  ```json
  {
    "protocolVersion": "1",
    "clientCapabilities": {
      "fs": { "readTextFile": false, "writeTextFile": false },
      "terminal": false
    }
  }
  ```
- `x.ai/billing` result shape (all monetary values are `{ val: <cents> }`):
  ```json
  {
    "billingCycle": {
      "billingPeriodStart": "2026-05-01T00:00:00Z",
      "billingPeriodEnd": "2026-06-01T00:00:00Z"
    },
    "monthlyLimit": { "val": 99900 },
    "onDemandCap": { "val": 0 },
    "on_demand_enabled": false,
    "disabledByConfig": false,
    "usage": {
      "includedUsed": { "val": 12345 },
      "onDemandUsed": { "val": 0 },
      "totalUsed": { "val": 12345 }
    }
  }
  ```
- Auth errors surface as JSON-RPC errors with the message
  `"Authentication required to fetch billing data. Run 'grok login' to authenticate."`.
- Timeouts: 8s for `initialize`, 12s for `x.ai/billing`. CodexBar terminates the
  child `grok` process on timeout to avoid leaking subprocesses.

## Mapping to `UsageSnapshot`

- **Primary window** = credit usage (against the subscription/included limit):
  - CLI RPC: `usedPercent` = `usage.totalUsed.val / monthlyLimit.val * 100`;
    `resetsAt` = `billingCycle.billingPeriodEnd`.
  - CLI-proxy fallback: `usedPercent` from the JSON percent or on-demand ratio;
    `resetsAt` from the current-period end or billing-period end.
  - grok.com fallback: `usedPercent` and `resetsAt` parsed from the gRPC-web
    billing protobuf.
  - The UI label for the live usage bar is dynamic: "Weekly" or "Monthly"
    when `resetsAt` matches a common cycle, falling back to the registered
    "Credits" label otherwise. Settings and history views continue to use
    "Credits" as the stable metric name.
- **Identity**:
  - `accountEmail` from credential `email`.
  - `accountOrganization` from credential `team_id`.
  - `loginMethod` = CLI settings `subscription_tier_display` when present
    (`SuperGrok Heavy` or `SuperGrok`), on both the CLI RPC route and the
    CLI-proxy web route. Otherwise "SuperGrok" for OIDC and the raw `auth_mode`
    for other login modes.

## Local fallback (`~/.grok/sessions/`)

Each session directory contains `signals.json` with fields like:

```json
{
  "turnCount": 1,
  "contextTokensUsed": 2968,
  "contextWindowTokens": 512000,
  "totalTokensBeforeCompaction": 0,
  "modelsUsed": ["grok-build"],
  "primaryModelId": "grok-build",
  "sessionDurationSeconds": 47
}
```

CodexBar aggregates these into a `GrokLocalSessionSummary` (session count, total
tokens, last session time, primary model, per-day token buckets) and exposes it for
diagnostics even when the RPC path is unavailable.

Those local daily token buckets also feed the shared Usage & Spend catalog so an
enabled Grok subscription is counted instead of omitted. SuperGrok/X Premium+
credits remain a quota window on the usage bar; they are never converted into
dollars. Local session scans run on the dedicated background usage-scan queue;
menu cards and spend views reuse the already-published snapshot instead of
walking the session directory whenever they render.

## Status

xAI has not exposed a Statuspage-style status feed yet. The "View Status" link
points to `https://status.x.ai`.

## Key files

- `Sources/CodexBarCore/Providers/Grok/GrokProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokAuth.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokPlan.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokRPCClient.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokCreditsProxyFetcher.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokCLISettingsFetcher.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokWebBillingFetcher.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Grok/GrokLocalSessionScanner.swift`
- `Sources/CodexBar/Providers/Grok/GrokProviderImplementation.swift`
