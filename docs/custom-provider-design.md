---
summary: "Accepted security and architecture boundary for declarative HTTP JSON providers."
read_when:
  - Evaluating issue 1735
  - Designing runtime-defined provider identities
  - Reviewing configurable endpoint or response-mapping changes
---

# Declarative custom provider design

Status: accepted design boundary. This document defines a bounded MVP; it does not authorize runtime networking or
implement the feature.

Issue: [#1735](https://github.com/steipete/CodexBar/issues/1735)

## Decision summary

A declarative provider can reduce one-off integrations, but it is not a small extension of LLM Proxy or LiteLLM.
Those providers still have compile-time `UsageProvider` identities, descriptors, implementations, request shapes, and response
decoders. A custom provider adds two new trust boundaries:

1. a config file chooses where CodexBar sends a secret;
2. untrusted response data controls user-visible usage, cost, and identity fields.

Accepted direction: pursue a config-only, GET-only, HTTP JSON MVP after separating runtime provider instance identity
from the closed `UsageProvider` enum. Do not add a single `.custom` enum case: multiple configured providers would then
collide in caches, status items, history, widgets, and settings.

## Current constraints

- `ProviderConfig.id` decodes directly as `UsageProvider`.
- `ProviderDescriptorRegistry` bootstraps exactly one descriptor for every `UsageProvider.allCases` value.
- `ProviderImplementationRegistry` constructs implementations with an exhaustive `UsageProvider` switch.
- Usage, errors, status, history, icons, settings, and menu state are keyed by `UsageProvider` across the app.
- The settings sidebar now persists provider-pane selection as `provider:<UsageProvider.rawValue>` and still assumes one
  pane per compile-time provider, reinforcing that dynamic identities need the shared seam rather than a parallel UI path.
- LLM Proxy and LiteLLM accept a configured base URL, but their request paths, auth header, decoding, and snapshot
  mapping remain provider-specific Swift code.
- `ProviderEndpointOverrideValidator` already provides hardened HTTPS host parsing and an explicit loopback-HTTP mode,
  while `ProviderHTTPClient` limits redirects to the same HTTPS origin. Reuse those primitives, but add a custom-provider
  policy for fragments, auth-dependent loopback rules, redirect rejection, response limits, and secret-safe errors.

## Proposed MVP contract

### Configuration

Keep the existing provider array and introduce config version 2 with a tagged provider definition. Existing entries remain
first-party definitions; custom entries have a stable user-chosen instance ID and a fixed implementation kind.

```json
{
  "version": 2,
  "providers": [
    {
      "id": "acme-gateway",
      "kind": "custom-http-json",
      "label": "Acme Gateway",
      "enabled": true,
      "request": {
        "method": "GET",
        "url": "https://gateway.example.com/v1/quota",
        "authentication": { "type": "bearer" }
      },
      "mapping": {
        "primary": {
          "usedPercent": { "path": "quota.used_pct" },
          "resetsAt": { "path": "quota.reset_at", "dateFormat": "iso8601" },
          "windowMinutes": { "path": "quota.window_minutes" }
        },
        "cost": {
          "used": { "path": "spend.usd" },
          "currency": "USD",
          "period": "Approx. spend"
        },
        "identity": {
          "organization": { "path": "plan.name" },
          "loginMethod": { "literal": "api" }
        }
      }
    }
  ]
}
```

Rules:

- `id`: lowercase ASCII letters, digits, and hyphens; 1–64 characters; unique across first-party and custom providers.
- `label`: required, trimmed, 1–80 characters. MVP uses a built-in generic icon.
- `method`: only `GET`.
- `authentication`: `none`, `bearer`, or `x-api-key`; the secret is never inline. Authenticated instances read only their
  derived variable `CODEXBAR_CUSTOM_<INSTANCE_ID>_API_KEY`, with the ID uppercased and hyphens replaced by underscores.
  A definition cannot name an arbitrary environment variable or header; bearer uses `Authorization` and x-api-key uses
  `X-API-Key`.
- `mapping.primary`: optional. When present, requires exactly one of `usedPercent` or `remainingPercent`. Optional fields
  are omitted when their paths are missing or null.
- `mapping.cost`: when present, requires `used`; `currency` is a three-letter uppercase literal and `period` is a bounded
  literal. A missing limit maps to zero, matching existing sparse cost snapshots.
- `mapping.identity`: optional bounded strings. The configured provider instance ID, not response data, owns snapshot
  identity.
- A definition that produces neither a rate window nor cost data is invalid.

### Mapping language

Use a typed dot-path subset, not JSONPath, jq, JavaScript, predicates, or string interpolation.

Grammar:

```text
path       = segment *("." segment / "[" index "]")
segment    = ALPHA *(ALPHA / DIGIT / "_" / "-")
index      = 1*DIGIT
```

Each target field determines its accepted type. Number coercion accepts JSON numbers and finite numeric strings only.
Percentages are clamped to 0–100 after rejecting NaN and infinity. Dates require an explicit format: `iso8601`,
`unix-seconds`, or `unix-milliseconds`. Display strings are trimmed and length-limited. Missing optional paths do not fail
the whole snapshot; a present value with the wrong type does.

No wildcards, recursive descent, filters, arithmetic, template evaluation, or user-supplied code. Multi-window arrays and
aggregation are later design work.

Hard limits: 16 mapped leaves per definition; 256 UTF-8 bytes and 32 components per path; 64 ASCII characters per
segment; array indices 0–4095; response JSON nesting depth 64; mapped display strings 256 UTF-8 bytes. Validate these
limits before traversal. Preflight structural nesting directly on the bounded response bytes with an iterative,
string-aware scanner before materializing JSON, so a hostile nested payload cannot exhaust the call stack.

### Network and secret boundary

- Require HTTPS for authenticated requests. Allow HTTP only for an unauthenticated loopback URL (`localhost`,
  `127.0.0.0/8`, or `::1`). Reject URL user info and fragments.
- Extend `ProviderEndpointOverrideValidator`; do not create a second URL parser. Use a dedicated
  `ProviderHTTPClient` configuration that rejects every redirect, even though the shared client safely permits same-origin
  HTTPS redirects.
- Bind the secret to the validated origin. Disable redirects for MVP; a 3xx response is an error.
- Before any custom-provider fetch, require a local approval record binding the instance ID, complete normalized request
  URL, origin, and auth type. Authenticated approvals also bind the fixed header and derived variable name. Store this
  record outside the provider config. First use requires explicit app or interactive CLI confirmation that displays the
  exact normalized URL and auth fields; headless use fails closed. No import or bulk-approval path is allowed. Loopback,
  IP-literal, `.local`, and visibly private targets require typing the normalized URL instead of accepting a button. Any
  bound-field change invalidates approval before the next fetch. This gate applies to unauthenticated loopback HTTP too.
- Never interpolate a secret into a URL, path, query, body, label, mapping, diagnostic, or log.
- Resolve the derived environment variable only after approval, when the provider is enabled and a fetch starts. Do not
  enumerate the environment.
- Use a dedicated `URLSessionConfiguration.ephemeral` session with `httpCookieStorage = nil`,
  `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, `urlCache = nil`, and a reload-ignoring-local-cache policy.
  Do not share a session with first-party providers. A dedicated challenge handler allows normal server-trust evaluation
  only and cancels client-certificate or HTTP authentication challenges.
- Send `Accept-Encoding: identity`, reject a non-identity `Content-Encoding`, and enforce the streaming 1 MiB cap on bytes
  delivered after URL loading's decoding and before JSON materialization. Cancel the task when the cap is exceeded. Use a
  15-second total timeout and a JSON content-type check.
- Accept only 2xx responses. Error text may include status and a bounded generic summary, never request headers or the raw
  response body.
- Keep custom-provider response data out of provider status polling, cookie import, OAuth, Keychain, token accounts,
  browser automation, and CLI subprocess paths.
- Custom definitions must be local config only. No remote catalogs, downloaded definitions, or config URLs.

### Runtime identity seam

Introduce a `ProviderInstanceID` string value that identifies one configured instance. Keep `UsageProvider` as the
compile-time implementation kind for first-party providers.

```text
ProviderDefinition
  firstParty(instanceID, UsageProvider, ProviderConfig)
  customHTTPJSON(instanceID, CustomHTTPJSONConfig)
```

Migrate runtime dictionaries, persistence keys, `ProviderIdentitySnapshot.providerID`, and identity accessors that
represent an enabled provider instance to `ProviderInstanceID`. First-party instance IDs retain their current raw values,
preserving existing config and stored history. Provider-specific fetchers continue to receive `UsageProvider`; the custom
fetcher receives only its validated custom definition. Provider-specific identity payloads remain keyed by their
compile-time implementation kind, while shared organization and login-method fields belong to the provider instance.

This seam must land independently with characterization tests before the custom network path. It prevents a custom
provider from being threaded through exhaustive first-party switches or sharing state with another custom instance.

## Threat model

| Threat | Required mitigation |
|---|---|
| Shared or malicious config exfiltrates a secret | Dedicated per-instance variable; separate full-URL/auth approval before secret resolution; config changes invalidate approval; redirects disabled |
| Endpoint redirects auth to another host | Treat every redirect as failure |
| Shared config silently probes or changes a GET target | No network access before separate full-URL approval; any URL change invalidates it; no bulk approval; elevated confirmation for visibly local/private targets |
| Hostile JSON causes CPU or memory pressure | 1 MiB cap; bounded depth and path length; no recursive expressions; request timeout |
| Response injects misleading or huge menu text | Typed targets; numeric bounds; string trimming and length limits; configured identity wins |
| Secret or response leaks through diagnostics | Redacted request description; no headers or raw response body in errors/logs |
| Two custom providers overwrite one another | Stable `ProviderInstanceID` keys throughout runtime and persistence |
| Config silently changes first-party behavior | Tagged definition; versioned decoder; duplicate/reserved ID rejection; migration tests |

Out of scope: defending a user from a request URL they explicitly approved, including a public hostname that later
resolves to a local or private address. Approval grants that origin network authority for the approved URL; the
confirmation must state this clearly. CodexBar still must contain the service response and must never disclose unrelated
credentials.

## Explicit non-goals

- Settings UI for creating or editing custom providers.
- Full JSONPath, jq, scripts, plugins, transforms, arithmetic, or templates.
- POST/PUT/PATCH/DELETE, request bodies, refresh mutations, or multiple endpoints.
- Arbitrary headers, cookies, OAuth, browser sessions, Keychain discovery, file-secret references, or inline secrets.
- Custom SVG/file icons, downloaded assets, or remote provider manifests.
- Status-page discovery, incident notifications, chat/model APIs, cost-log scanning, widgets, or token accounts.
- Arrays of rate windows, cross-response joins, pagination, aggregation, or provider-specific special cases.
- Compatibility shims that reinterpret an unknown first-party provider ID as a custom provider.

## Implementation slices

1. **Identity seam:** add `ProviderInstanceID`; migrate config/runtime/persistence keys without behavior changes; add
   decode, history, enablement, menu, CLI, and widget characterization tests.
2. **Pure evaluator:** add config types, validator, dot-path parser, typed coercion, and `UsageSnapshot` mapping using only
   fixture data.
3. **Bounded transport:** add URL/auth policy and an injected HTTP transport; prove redirect, timeout, size, content-type,
   status, and redaction behavior.
4. **Config and CLI integration:** version-2 migration, `codexbar config validate`, local approval records and interactive
   approval command, diagnostics, and custom-provider CLI output. No live credentials in tests.
5. **App integration:** generic metadata/icon, refresh lifecycle, menu rendering, persistence, and disabled/error states
   through existing shared provider UI.

Each slice should be a separately reviewable PR. Do not combine the identity migration and arbitrary networking in one
change.

## Required proof before enabling the feature

- Config v1 round-trip and v1-to-v2 migration preserve every existing provider entry.
- Duplicate, reserved, malformed, and colliding instance IDs fail validation.
- Multiple custom instances keep snapshots, errors, histories, menu selection, and persistence isolated.
- URL table covers HTTPS, user info, fragments, loopback HTTP, private/public HTTP, IPv4/IPv6, ports, and redirects.
- Auth tests prove the secret reaches only the intended header and never URL, errors, fixtures, snapshots, or logs.
- Approval tests prove first use and every bound-field change fail closed before network or environment access, and that
  one instance cannot reuse another instance's approval or derived secret variable. UI/CLI proof covers exact-URL
  display, no bulk approval, and typed confirmation for loopback, IP-literal, `.local`, and visibly private targets.
- Mapping tests cover missing/null paths, arrays, wrong types, date formats, finite-number enforcement, every numeric
  path/depth/count bound, iterative depth rejection, and string limits.
- Transport tests cover timeout, cancellation, decoded response cap, compressed-response rejection, content type,
  non-2xx, and 3xx without live network access.
- Transport isolation tests prove ambient cookies and URL credentials are neither sent nor persisted and cached responses
  are not reused.
- Source-blind CLI proof: a fixture endpoint plus isolated config produces the expected usage, cost, identity, and redacted
  failure output.
- `make test`, `make check`, structured autoreview, and exact-head CI are green for every implementation PR.

## Accepted owner decisions

1. Declarative provider support is worth the runtime identity migration and long-term versioned schema support.
2. MVP may use unauthenticated loopback HTTP only under the same separate approval gate, including typed confirmation of
   the normalized URL. Every authenticated request requires HTTPS.
3. A derived per-instance environment variable plus local URL/auth approval is the only MVP secret source. Keychain
   storage is deferred; the initial design must not imply or preserve a second secret path.
4. MVP supports one primary rate window, with cost and identity optional. Multi-window and aggregation semantics remain
   out of scope.
5. The first integrated surface is CLI-only. App settings and menu integration wait until the shared runtime accepts
   dynamic identities without provider-specific side paths.

Implementation gate: keep custom-provider networking disabled until the independent identity migration, pure evaluator,
bounded transport, approval flow, and their required proof land as separately reviewable changes. If an implementation
cannot preserve this boundary, stop rather than shipping a single `.custom` slot, a parallel UI path, or a compatibility
fallback.
