---
summary: "JavaScript provider-plugin prototype API, engine benchmark, safety boundary, enablement, and limitations."
read_when:
  - Working on the JavaScript provider prototype
  - Converting a first-party provider to a bundled JavaScript resource
  - Reviewing the plugin sandbox or parity tests
---

# JavaScript provider-plugin prototype

This document describes the bundled first-party conversion prototype. User-installed files use the production path in
[`plugins.md`](plugins.md); they do not depend on `CODEXBAR_JS_PROVIDERS`.

This prototype proves that an existing first-party `UsageProvider` can define its manifest, HTTP requests, response
parsing, and generic `UsageSnapshot` projection in one bundled JavaScript file. It is deliberately not a user-plugin
system: IDs remain compile-time `UsageProvider` cases and scripts ship inside CodexBar. Crof, Venice, OpenRouter,
ClawRouter, Deepgram, sub2api, Synthetic, Poe, xAI, and z.ai use the same bundled script on Apple platforms and Linux;
their native fetch twins have been removed.

The runtime selects QuickJS on every platform. QuickJS uses a 20-second in-engine interrupt watchdog, a 64 MiB heap
limit, and a 2 MiB JavaScript stack limit. On Apple platforms, set `CODEXBAR_PLUGIN_ENGINE=jsc` or enable the
JavaScriptCore rollback in **Settings → Debug → Provider Plugins** and restart CodexBar. An explicit engine environment
value overrides the persisted Debug setting. JavaScriptCore remains in-tree for rollback and A/B drift detection.

## Engine benchmark

The test-only `ProviderPluginEngineBenchmarkTests` instrumentation compares both engines without pass/fail thresholds.
Run it on macOS with
`CODEXBAR_PLUGIN_BENCHMARK=1 swift test --filter ProviderPluginEngineBenchmarkTests`. The August 8, 2026 baseline below
was captured from a Swift debug build on an Apple M3 Ultra. Creation includes loading and linting each bundled source,
creating its runtime, and reading its manifest; values are the median of five samples in milliseconds.

| Bundled plugin | JavaScriptCore | QuickJS |
| --- | ---: | ---: |
| clawrouter | 2.167 | 3.563 |
| crof | 1.606 | 1.736 |
| deepgram | 2.074 | 3.127 |
| manus | 0.907 | 4.241 |
| openai | 2.859 | 4.279 |
| openrouter | 1.901 | 3.333 |
| perplexity | 1.114 | 3.861 |
| poe | 1.972 | 3.681 |
| qoder | 0.863 | 2.362 |
| sub2api | 2.848 | 4.018 |
| synthetic | 2.617 | 5.985 |
| t3chat | 1.521 | 1.734 |
| venice | 1.483 | 1.881 |
| xai | 1.359 | 2.470 |
| zai | 2.862 | 8.986 |

Fetch timings reuse one context for 50 iterations with fixture transport. Poe exercises all five history pages with
100 entries per page, OpenRouter performs its credits and key requests, and Crof performs its single usage request.
Memory is a rough macOS task physical-footprint delta while retaining all 15 contexts, divided by context count.

| Engine | Poe (50) | OpenRouter (50) | Crof (50) | Rough peak delta/context |
| --- | ---: | ---: | ---: | ---: |
| JavaScriptCore | 321.237 ms | 36.424 ms | 23.917 ms | 806.4 KiB |
| QuickJS | 1000.066 ms | 90.610 ms | 38.119 ms | 117.3 KiB |

At this representative workload QuickJS trades roughly 1.6–3.1× fetch time for a much smaller measured context
footprint. All operations stay well below the 20-second watchdog; these figures are instrumentation for future engine
work, not a performance contract.

Plugin manifests and their projected snapshots now carry a validated `ProviderInstanceID`. The prototype still maps
that instance ID to an existing first-party `UsageProvider` before using browser-cookie brokerage or other bespoke
provider paths, and the widget's `AppEnum` still lists only first-party cases. User-installed plugins without an enum
case therefore remain out of scope for this prototype.

## Enable and test

Set `CODEXBAR_JS_PROVIDERS=1` in CodexBar's environment. OpenAI, Manus,
Perplexity, T3 Chat, and Qoder then prepend a script strategy to their existing pipeline.
A missing required secret or disabled cookie source leaves the script
strategy unavailable and permits the Swift strategy to run; a loaded script that fails does not fall back, so parity
defects stay visible. Without the variable, the resolver returns the original Swift strategy only and does not load
an engine or plugin resource for those providers. Crof, Venice, OpenRouter, ClawRouter, Deepgram, sub2api, Synthetic,
Poe, xAI, and z.ai always resolve only their script strategy on every platform; `CODEXBAR_JS_PROVIDERS` does not affect
them.

Run the focused proof with:

```sh
swift test --filter ProviderPluginRuntimeTests
swift test --filter ProviderPluginParityTests
swift test --filter ProviderPluginDetailsParityTests
./Scripts/test-plugin-engines.sh
```

The parity suites send canned responses through an injected `ProviderHTTPTransport`. Flag-gated providers compare the
Swift and JavaScript implementations, while cut-over providers use JavaScript goldens for windows, percentages, reset
dates, cost, subscription dates, identity, and complete declarative detail output.

## Manifest

Every script calls `defineProvider` once:

```js
defineProvider({
  id: "example", // must be an existing UsageProvider raw value
  name: "Example",
  endpoints: [
    "https://api.example.com", // fixed HTTPS origin
    { setting: "BASE_URL", policy: "https-or-loopback-http" },
  ],
  auth: {
    type: "bearer", // bearer | x-api-key | header | authorization-scheme
    header: "X-Custom-Key", // required only for type: "header"
    secret: "EXAMPLE_API_KEY", // key declared below
  },
  settings: [{
    key: "EXAMPLE_API_KEY",
    title: "API key",
    subtitle: "Where to obtain the key.",
    type: "secure", // secure | plain
  }],
  async fetchUsage(ctx) {
    const response = await ctx.http.getJSON("https://api.example.com/v1/usage");
    return { primary: { usedPercent: response.json.usedPercent } };
  },
});
```

Fixed `endpoints` accept only normalized HTTPS origins. A settings-derived endpoint declares a plain setting and a
policy: `https` or `https-or-loopback-http`. It is resolved at fetch time using the same endpoint-override validation
as native providers; user info and fragments are rejected, and HTTP is limited to loopback under the latter policy.
`bearer` injects `Authorization: Bearer <secret>`, `x-api-key` injects `X-API-Key`, and `header` injects the named
header. `authorization-scheme` requires a bounded ASCII token in `scheme` and injects
`Authorization: <scheme> <secret>`. A plugin cannot override a manifest-owned auth header.

Cookie plugins omit `auth`, declare `capabilities: ["browser-cookies"]`, and list normalized host names in
`cookieDomains`. The host refuses undeclared domains before cache or browser-store access.

## `ctx` reference

`ctx` exists only as the argument to `fetchUsage`; it is not a global. QuickJS and the JavaScriptCore rollback engine
supply standard ECMAScript built-ins, but no browser or Node host environment. Tests assert that `fetch`,
`XMLHttpRequest`, `setTimeout`, and `setInterval` are undefined.

- `await ctx.http.getJSON(url, opts?)` performs a GET and returns `{status, headers, json}`.
- `await ctx.http.get(url, opts?)` performs a GET and returns `{status, headers, bodyText}`.
- `await ctx.http.postJSON(url, {body, headers?})` performs a POST and returns `{status, headers, json}`. `body` must be
  JSON-serializable. The serialized body is passed directly to the broker and is never logged.
- `opts.headers` may contain string header values. `opts.timeoutSeconds` sets a hard deadline from 1 through 30 seconds
  (default 15), responses are capped at 5 MiB, and transport uses `ProviderHTTPClient`, including its same-origin HTTPS
  redirect policy.
- `ctx.settings.get(key)` reads only a declared `plain` setting; `ctx.settings.getSecret(key)` reads only a declared
  `secure` setting. Kind mismatches and undeclared keys throw. Only secure values are tracked for redaction.
- `ctx.fail` creates typed host failures for authentication, missing credentials, permission, rate limiting, provider
  availability, parsing, network, and API errors. Plugins throw the returned error; ordinary exceptions retain the
  generic script-error mapping.
- `await ctx.browser.cookieHeader(domain)` returns a Cookie header only for a declared domain and only when the
  `browser-cookies` capability is present. The broker honors the provider's auto/manual/off setting, cache, and browser
  priority order. Cookie headers and individual cookie values are secret-equivalent and redacted at the bridge.
- `ctx.html.metaContent(html, name)` returns the first matching quoted `name`/`property` meta value, or `null`.
  `ctx.html.matchFirst(html, regexSource, flags?)` returns the first capture (or full match), or `null`. Both are pure
  JavaScript helpers with no I/O.
- `ctx.log(...values)` writes to the provider-derived `<provider>-plugin` category. Do not log credentials; known secret
  values are also substring-redacted from errors crossing back to Swift.
- `ctx.cache.get(key)` and `ctx.cache.set(key, value, ttlSeconds)` provide an in-memory, per-context cache. TTLs are
  positive and capped at 24 hours.
- `ctx.date.now()`, `iso(text)`, `unixSeconds(number)`, and `unixMillis(number)` return JavaScript `Date` objects.
  `now()` uses the host refresh clock so fixtures and retries share the snapshot timestamp.
- `ctx.date.nextDailyReset(timeZoneIdentifier, hour)` returns the next wall-clock hour in an IANA time zone, including
  DST transitions. Crof uses `America/Chicago` at hour `0`.
- `ctx.jwt.decode(token)` decodes the JSON payload segment without verifying a signature.
- `ctx.pct(used, limit)` returns a finite percentage clamped to 0–100; a non-positive limit maps to 100.

## Snapshot result

`fetchUsage` resolves to an object containing at least one window or `cost`. `primary`, `secondary`, and `tertiary` are
optional `{usedPercent, resetsAt?, windowMinutes?, resetDescription?, nextRegenPercent?}` objects. `extraWindows` is an
optional array of `{id, title, window}`. Percentages must be finite numbers and are clamped to 0–100; window minutes must
be positive integers.

`cost` requires finite numeric `used` and a three-letter uppercase `currency`; `limit`, `period`, `resetsAt`,
`nextRegenAmount`, and `balance` are optional. A missing limit maps to zero. `identity` accepts bounded, trimmed `email`,
`organization`, `loginMethod`, and `accountID` strings; Swift always scopes it to the manifest provider ID.
`subscriptionRenewsAt` and `subscriptionExpiresAt` accept a JavaScript `Date` or ISO-8601 string. Missing optionals are
fine. `dataConfidence` accepts `exact`, `estimated`, `percentOnly`, or `unknown` and defaults to `unknown`; a present
value of the wrong type fails the entire fetch with its property path.

### Declarative details

`details` is an optional array of sections rendered generically in the provider menu card. A snapshot may contain
details without a rate window or cost. Each section has optional `title`, required `rows`, and an optional simple chart:

```js
return {
  primary: { usedPercent: 25 },
  details: [{
    title: "Usage summary",
    rows: [
      { label: "Requests", value: "1,240", secondaryValue: "Last 30 days" },
      { label: "Top model", value: "gpt-5" },
    ],
    chart: {
      kind: "bars", // bars | line
      title: "Daily spend",
      unit: "USD",
      points: [
        { label: "2026-08-01", value: 4.25 },
        { label: "2026-08-02", value: 6.50 },
      ],
    },
  }],
};
```

The bridge rejects rather than truncates more than 8 sections, 24 rows per section, or 120 points per chart. Section,
row, chart, and point strings are trimmed and limited to 120 characters; required row/point strings must remain
non-empty. Point values must be finite numbers. A present value with the wrong type, an unknown chart kind, or any
bound violation fails the entire fetch with its property path.

## Concurrency and execution limit

Each runtime owns one engine context confined to a dedicated serial worker. QuickJS uses a 4 MiB native-stack thread,
leaving guard-page margin beyond its 2 MiB JavaScript stack limit. Promise `then`/rejection callbacks converge on a
lock-protected checked continuation gate, so network, timeout, and script completion can resume Swift exactly once.
QuickJS's `JS_SetInterruptHandler` stops evaluation on that worker when the 20-second watchdog fires;
the poisoned context is discarded and the next refresh creates a fresh one, which the hung-script recovery test proves.

The same hard-interrupt watchdog is production-default for first-party cut-over providers. It is part of the shared
runtime, not the prototype flag, so cut-over providers retain timeout and fresh-context recovery without
`CODEXBAR_JS_PROVIDERS`. The Apple-only JavaScriptCore rollback still uses a `JSContext` and `JSValue` objects confined
to its executor. The exported `JSContextGroupSetExecutionTimeLimit` symbol has no declaration in public macOS headers,
so the rollback path does not bind that private SPI: its watchdog returns to the caller and discards the poisoned
context, but it cannot interrupt the abandoned JavaScriptCore thread, which may remain alive until process exit.

## Current limitations

The remaining bundled-conversion flag is macOS-only and compiled out when JavaScriptCore is unavailable. It supports bundled
first-party IDs and the generic snapshot and declarative details only: no provider-specific Swift payloads,
OAuth/refresh broker, local files or databases, subprocesses,
arbitrary/form POST bodies, PTY, WebView, binary/protobuf responses, private-network HTTP, or unvalidated dynamic
origins. The separate user-plugin path adds local `.js`/`.ts` discovery, approval, and settings without changing these
first-party flag semantics. Browser cookies remain restricted to declared domains. See
[`plugin-conversion-matrix.md`](plugin-conversion-matrix.md) for the provider-by-provider impact.

## Remaining native-only payloads

Display-only provider payloads now use `details` on both the Swift and JavaScript paths. The remaining bespoke
`UsageSnapshot` fields drive behavior rather than presentation: Codex reset-credit actions, Command Code refresh
stabilization, DeepSeek profile selection/transition state, and provider-derived token-cost pipelines for OpenAI API,
Mistral, and OpenCode Go. They are not plugin compatibility shims.
