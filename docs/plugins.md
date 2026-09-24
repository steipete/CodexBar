---
summary: "Authoring, installing, approving, and operating local JavaScript and TypeScript provider plugins."
read_when:
  - Writing a CodexBar provider plugin
  - Installing or reviewing a local provider plugin
  - Debugging plugin approval, TypeScript, settings, or network behavior
---

# Local provider plugins

CodexBar can load one local JavaScript or TypeScript file as a provider. Put a `.js` or `.ts` file in
`~/.config/codexbar/providers/`, or choose **Settings → Plugins → Install…**. Each file declares its complete authority
and settings schema in a manifest, fetches through CodexBar's sandboxed host API, and returns a generic usage snapshot.

Plugins are local files only. CodexBar has no plugin catalog, does not download plugin code or assets, and does not
resolve imports. A plugin cannot use Node, browser globals, subprocesses, local files, databases, OAuth, WebViews, or
arbitrary native APIs. The maximum source size is 1 MiB.

App refreshes are scoped to the installed plugin runtime and its fetch settings. Disabling, removing, reloading, or
reconfiguring a plugin prevents an older refresh from publishing usage or errors. A replacement refresh waits for retired
work to finish and reads the current configuration when its fetch starts. Display-only preferences do not invalidate usage.

## Minimal plugin

```js
defineProvider({
  id: "acme-usage",
  name: "Acme Usage",
  icon: { monogram: "AC", tint: "#336699" },
  endpoints: ["https://api.example.com"],
  auth: { type: "bearer", secret: "API_KEY" },
  settings: [
    { key: "API_KEY", title: "API key", subtitle: "Create one in Acme settings.", type: "secure" },
  ],
  async fetchUsage(ctx) {
    const response = await ctx.http.getJSON("https://api.example.com/v1/usage");
    return {
      primary: {
        usedPercent: response.json.used_percent,
        resetsAt: response.json.resets_at,
        windowMinutes: 300,
      },
      details: [{
        title: "Usage",
        rows: [{ label: "Requests", value: String(response.json.requests) }],
      }],
    };
  },
});
```

## Manifest reference

`defineProvider` must be called exactly once with an object containing:

- `id`: 1–64 lowercase ASCII letters, digits, or hyphens. It must not match a built-in provider or another installed
  plugin.
- `name`: trimmed display name, 1–80 UTF-8 bytes.
- `icon` (optional): `{monogram, tint}`. `monogram` is 1–3 characters; `tint` is `#RRGGBB`. The fallback is the first
  letter of `name` with a neutral tint. File/SVG icons are not supported.
- `topLevel` (optional): set to `true` to give an enabled plugin its own provider-switcher tab. The default is `false`.
- `endpoints`: 1–16 declared network origins. A fixed endpoint is a normalized HTTPS origin such as
  `https://api.example.com` (no path, query, fragment, or user info). A settings-derived endpoint is
  `{setting: "BASE_URL", policy: "https"}`, `{setting: "BASE_URL", policy: "https-or-loopback-http"}`, or
  `{setting: "BASE_URL", policy: "https-or-private-network-http"}`. Its setting must be declared as `plain`.
  `https-or-loopback-http` preserves the unauthenticated loopback-only rule. `https-or-private-network-http` also permits
  authenticated HTTP for loopback, RFC 1918 IPv4, IPv4 link-local, IPv6 unique-local/link-local, and `.local` targets,
  but only through the separate typed approval described below. Public targets always require HTTPS.
- `auth` (optional): one of the forms below. The named secret must be a declared `secure` setting.
- `settings`: up to 32 setting definitions. Keys contain 1–64 ASCII letters, digits, or underscores and start with a
  letter. Each entry has `key`, `title`, optional `subtitle`, and `type: "plain" | "secure"` (default `secure`).
- `capabilities` (optional): `"browser-cookies"` and `"http-status"`. With `"http-status"`, the plugin observes
  non-2xx responses itself instead of the host failing the request.
- `cookieDomains`: required with `browser-cookies`; a non-empty list of normalized DNS host names.
- `fetchUsage(ctx)`: function returning a snapshot or fetch result envelope, or a promise for one.

Authentication forms:

```js
auth: { type: "bearer", secret: "API_KEY" }
auth: { type: "x-api-key", secret: "API_KEY" }
auth: { type: "header", header: "X-Custom-Key", secret: "API_KEY" }
auth: { type: "authorization-scheme", scheme: "Token", secret: "API_KEY" }
```

The host owns the authentication header; plugin request options cannot override it. Authenticated public origins must be
HTTPS; authenticated private-network HTTP requires `https-or-private-network-http` plus typed approval. Secure settings
can be overridden for CLI use with
`CODEXBAR_PLUGIN_<PLUGIN_ID>_<SETTING_KEY>`, uppercased with non-alphanumeric characters replaced by underscores. For
example, `acme-usage` and `API_KEY` use `CODEXBAR_PLUGIN_ACME_USAGE_API_KEY`.

## `ctx` API

`ctx` exists only during `fetchUsage`. CodexBar uses QuickJS on every platform; both QuickJS and the Apple-only
JavaScriptCore rollback engine provide ECMAScript built-ins but no browser or Node environment. `Intl` is
engine-dependent and unavailable in QuickJS,
so portable third-party plugins must use the host helpers below instead of ECMA-402. `fetch`, `XMLHttpRequest`, timers,
`require`, `process`, and filesystem APIs are unavailable.

- `await ctx.http.getJSON(url, opts?)` performs GET and returns `{status, headers, json}`.
- `await ctx.http.get(url, opts?)` performs GET and returns `{status, headers, bodyText}`.
- `await ctx.http.postJSON(url, {body, headers?})` performs JSON POST. `body` must be JSON-serializable.
- `await ctx.http.post(url, {body, headers?})` sends the same JSON POST and returns `{status, headers, bodyText}` so a
  plugin can classify non-JSON error pages before parsing a successful response.
- `opts.headers` accepts string values. Plugins cannot replace their declared auth header. `opts.timeoutSeconds` sets a
  hard request deadline from 1 through 90 seconds; the default is 15 seconds. Each attempt’s deadline starts when
  its transport task begins, so scheduler delays do not consume the request budget. Queued work remains bounded
  by the overall fetch deadline and cancellation. An override does not extend that overall deadline; bundled
  strategies that need a longer request must also supply a sufficient fetch budget.
- `opts.retryPolicy: "transientIdempotent"` opts GET into the native single-retry policy: 408, 429, 500, 502, 503, 504,
  timeout, lost connection, connection failure, and DNS failures. The delay is one second or numeric `Retry-After`,
  capped at ten seconds. POST, offline, TLS, and cancellation failures are not retried. This replaces the automatic
  status-based fetch replay for that request; explicit `ctx.fail` retry options should not add another retry.
- HTTP rejections are `Error` objects on both engines. Native failures expose `transportCode` (the Foundation URL-error
  code), `transportClass` (`timeout`, `dns`, `offline`, `cancelled`, `tls`, `connection`, or `other`), and `retryable`
  (the code's eligibility for an idempotent retry, not the remaining retry budget).
  Rejected HTTP responses expose `status` and class `http`. Plugins can use these fields when choosing a `ctx.fail`
  classification. Rethrow cancellation unchanged; uncaught cancellation remains a Swift `CancellationError`, and
  cancelling the refresh interrupts its pending request and retry delay.
- `ctx.settings.get(key)` reads a declared `plain` setting.
- `ctx.settings.getSecret(key)` reads a declared `secure` setting. Missing values return `null`; kind mismatches and
  undeclared keys throw.
- `ctx.fail` creates classified errors for `authenticationExpired`, `missingCredential`, `permissionDenied`,
  `rateLimited`, `providerUnavailable`, `parseFailure`, `networkFailure`, and `apiFailure`. Throw the returned error,
  for example `throw ctx.fail.rateLimited("Provider rate limit reached")`; ordinary errors retain generic mapping.
  Every plugin automatically gets one delayed retry when a request returns 408, 429, 500, 502, 503, or 504. A numeric
  `Retry-After` header sets the delay; otherwise the delay is 1 second, and the host clamps it to 10 seconds. A plugin
  that needs provider-specific handling—such as a non-numeric `Retry-After`, quota data in the error body, or a vendor
  retry field—declares `http-status`, receives the response, and throws `ctx.fail.rateLimited(message,
  {retryAfterSeconds})` or another transient classified failure. Both paths share one retry budget and never retry the
  retry. Cancellation during the delay stops the retry.
- `ctx.browser.availability(domain)` returns `"available"`, `"manual"`, or `"off"` for a declared cookie domain.
  It inspects source/cookie policy only, without accessing the broker, Keychain, or browser. It does not promise a
  usable session. API-only (and other non-web) source modes report `"off"`; Manual reports `"manual"`, so plugins can
  route an origin-less pasted header to one explicitly selected tenant. Missing cookie resolvers report `"off"`.
  `cookieHeader` also enforces Off/API-only policy, even if the plugin skips this check.
- `await ctx.browser.cookieHeader(domain)` returns a cookie header only with the `browser-cookies` capability and for a
  declared domain. User plugins import from Chrome; bundled providers retain their declared browser order.
  Cookie values are secret-equivalent and redacted.
- `for await (const session of ctx.browser.sessions(domain))` visits origin-bound candidates in order: the exclusive
  manual credential, or the cached session followed by browser profiles in the provider's import order. Each candidate
  has `{id, header, source, origin}`. Enumeration is scoped to one declared domain and stops when candidates are exhausted.
  Manual regional captures retain their origin through settings projection; an origin-less legacy header is restricted
  to the selected domain. Qoder's legacy headers select the global site.
  The optional `{cachedOnly: true}` argument yields manual/cached candidates without importing browser profiles;
  cached candidates include `cachedAt` as Unix seconds. This lets a regional provider try its newest cached session
  before importing any fresh cookies, even when that session belongs to its second domain.
- `ctx.browser.rejectCookie(domain, session)` rejects that candidate after an authentication failure. It conditionally
  evicts the matching persistent entry without deleting a newer session or another domain's cache. The opaque candidate
  ID makes late rejections safe. Continuing the iterator visits the next candidate; a successful fetch can return
  immediately. `cookieHeader` remains available for providers needing only one header.
- `ctx.html.metaContent(html, name)` returns the first matching quoted meta value or `null`.
- `ctx.html.matchFirst(html, regexSource, flags?)` returns the first capture/full match or `null`.
- `ctx.log(...values)` writes to the instance-scoped plugin log. Known secrets and cookie values are redacted.
- `ctx.cache.get(key)` and `ctx.cache.set(key, value, ttlSeconds)` provide a per-runtime memory cache. TTL is capped at
  24 hours.
- `ctx.date.now()`, `iso(text)`, `unixSeconds(number)`, and `unixMillis(number)` create JavaScript dates. `now()` uses
  the host refresh clock.
- `ctx.date.nowMillis()` returns the same host refresh clock as Unix epoch milliseconds — use it for arithmetic that
  should stay deterministic under fixture clocks (the z.ai quota-rate row does).
- `ctx.date.nextDailyReset(timeZoneIdentifier, hour)` returns the next wall-clock reset in an IANA time zone.
- `ctx.env.timeZone` is the host's current IANA time-zone identifier; zero-offset GMT aliases are normalized to `UTC`.
- `ctx.format.number(value, options?)`, `usd(value)`, and `monthDay(date)` provide deterministic formatting on both
  engines. Number options support `minimumFractionDigits` and `maximumFractionDigits`.
- `ctx.format.currency(value, currencyCode)` uses the same native `UsageFormatter` as the app, with `en_US` currency
  symbols and decimal half-even rounding. For USD, `49.585` becomes `$49.58`, `-0.0` becomes `-$0.00`, and `1e-7`
  becomes `$0.00`; CNY uses `CN¥`. No JavaScript `Intl` implementation is required.
- `ctx.jwt.decode(token)` decodes (but does not authenticate) a JWT JSON payload.
- `ctx.pct(used, limit)` returns a finite percentage clamped to 0–100; non-positive limits map to 100.
- `ctx.isDetailLabel(value)` checks the native provider-detail label rules, including whitespace and Unicode character limits; it performs no I/O and returns false for non-strings.

User-plugin requests run in an ephemeral session with no ambient cookies, credential store, or URL cache. Redirects are
rejected, the default request timeout is 15 seconds, `Accept-Encoding: identity` is sent, compressed responses always fail, and response
bytes are capped at 1 MiB. By default, the host rejects non-2xx responses and automatically retries 408, 429, 500, 502,
503, and 504 once, using a numeric `Retry-After` delay or 1 second when absent, clamped to 10 seconds. With `http-status`,
the plugin instead receives `{status, headers, ...}` and owns classification, including any request for the same single
delayed retry. Request URLs must match a declared, approved origin.

```js
capabilities: ["http-status"],
async fetchUsage(ctx) {
  const response = await ctx.http.getJSON("https://api.example.com/usage");
  if (response.status === 429) {
    const retryAfterSeconds = Number(response.headers["retry-after"] || 1);
    throw ctx.fail.rateLimited("Rate limited", { retryAfterSeconds });
  }
}
```

Declaring `http-status` changes the approval binding, so an installed plugin requires re-approval after adding it.

Bundled first-party providers that have cut over to JavaScript use the shared runtime's 20-second hung-script watchdog.
A timeout fails that refresh and discards the poisoned worker so the next refresh starts with a fresh context; this is
production-default and does not depend on `CODEXBAR_JS_PROVIDERS`.
QuickJS enforces the watchdog in-engine with `JS_SetInterruptHandler`, caps the runtime heap at 64 MiB, and caps the
JavaScript stack at 2 MiB. The interrupt terminates evaluation on its confined thread; timed-out scripts do not leave an
abandoned evaluation thread behind. On Apple platforms, `CODEXBAR_PLUGIN_ENGINE=jsc` selects the JavaScriptCore rollback
engine; the same rollback is available in **Settings → Debug → Provider Plugins** and takes effect after restarting
CodexBar. JavaScriptCore has no public interrupt API, so a timed-out rollback-engine context is discarded but its
abandoned evaluation thread can remain alive until process exit.

## Snapshot result

Return at least one rate window, cost object, detail section, or non-empty identity field:

```js
return {
  primary: { usedPercent: 25, resetsAt: new Date(), windowMinutes: 300 },
  secondary: { usedPercent: 40, resetsAt: "2026-08-10T00:00:00Z", windowMinutes: 10080 },
  tertiary: { usedPercent: 5 },
  extraWindows: [{ id: "daily", title: "Daily", window: { usedPercent: 12 } }],
  cost: { used: 8.5, limit: 20, currency: "USD", period: "This month", balance: 11.5 },
  identity: { email: "user@example.com", organization: "Acme", loginMethod: "API key", accountID: "123" },
  subscriptionRenewsAt: "2026-09-01T00:00:00Z",
  dataConfidence: "exact", // exact | estimated | percentOnly | unknown
  details: [{
    title: "Usage summary",
    rows: [{ label: "Requests", value: "1,240", secondaryValue: "Last 30 days" }],
    chart: {
      kind: "bars", // bars | line
      title: "Daily spend",
      unit: "USD",
      points: [{ label: "2026-08-01", value: 4.25 }],
    },
  }],
};
```

Percentages must be finite and are clamped to 0–100. Window minutes are positive integers. Cost requires finite `used`
and a three-letter uppercase currency. Dates are JavaScript `Date` values or ISO-8601 strings. Snapshot identity is
always scoped to the manifest's instance ID. Data confidence defaults to `unknown`. Details allow at most 8 sections, 24 rows per section, 120 chart points,
and 120 characters per detail string. Wrong types and limit violations fail the whole fetch instead of truncating it.
Named extra windows accept an optional `usageKnown` boolean (default `true`). Set it to `false` for reset-only limits:
the window remains visible as **Unavailable**, and its placeholder `usedPercent` is not presented as measured usage.
Detail rows accept optional `progress` (a finite consumed fraction from 0 through 1) and `usageValue` (finite raw usage).
The host maps the fraction to native progress with `used: progress, total: 1`; `usageValue` is preserved independently.
Absent or null numeric fields leave existing text-only rows unchanged. A supplied `usageKnown` must be a boolean,
including when the window uses the nested `window` form; null is invalid.
An identity-only snapshot is useful for balance-only or zero-usage provider states and renders its available account,
organization, plan/login-method, and account-ID fields in the menu and CLI. A verified response with no displayable data
may return `{empty: true}` with optional identity. This creates no artificial rate window; every supplied field is still
validated. An empty object, an empty `identity` object, or metadata such as confidence and subscription dates without
displayable usage or identity remains invalid unless `empty: true` is explicitly declared.

## Fetch result envelope

`fetchUsage` may return a bare snapshot or `{ usage, sourceLabel?, card?, persist? }`. The two forms cannot be mixed;
unknown result and top-level snapshot keys fail validation. Both engines apply the same mapper before any settings write.
Session iteration and candidate rejection work with either result form; the Swift `fetchUsage` and `fetchResult` entry
points both preserve the caller's cookie-session resolver and invalidator.
`sourceLabel` replaces the strategy's default label for that fetch and must contain 1–256 UTF-8 bytes without control
characters. `persist` is an object with at most 16 string values of 1–256 bytes; the descriptor must explicitly allow
every key. Null, arrays, wrong types, unknown keys, and cross-provider requests fail the entire result.

Card payloads are descriptor-owned, never arbitrary Swift decoding. OpenAI's `card.openAIAPIUsage` adapter accepts daily
cost, token, request, model, and line-item history for the existing native chart. It rejects unknown fields, bounds the
history to 366 buckets and 10,000 breakdown entries, and validates finite numbers, safe integer counts, names, and dates.
No other provider or user-installed plugin receives that adapter by declaring a card field.

Fireworks alone allows `persist: { ACCOUNT_SLUG: "discovered-slug" }`. The app/CLI writer rechecks ownership, applies the
provider's allowlist, and returns saved, unchanged, stale, or failed. Successful usage survives a stale or failed save
with a diagnostic. The runtime itself never writes config; a missing writer also reports a failed save. There is no
secret-write capability or arbitrary config-field access.

## TypeScript

llmman's bundled `llmman.ts` reads a local `llmman serve` daemon's node report for loaded-model memory. Its API key is
optional, so the plugin sends it itself instead of declaring host-owned `auth`. See [llmman](llmman.md).

Chutes' bundled `chutes.ts` owns subscription usage and best-effort quota detail requests on both engines. It preserves
subscription context and explicitly permits empty usage responses. Swift supplies credentials and validated API origins.
See [Chutes](chutes.md).

ai&'s bundled `aiand.ts` follows paired log cursors and sums decimal costs with integer arithmetic before the final
display conversion. Empty windows omit cost; capped or incomplete pagination retains estimated confidence.
See [ai&](aiand.md).

DevPass's bundled `devpass.ts` reads the documented LLM Gateway key-status API for billing-cycle and premium weekly
credits. Swift only registers the provider and its API-key setting. See [DevPass](devpass.md).

Moonshot's bundled `moonshot.ts` runs on both engines. Its Swift descriptor resolves the regional credential and passes
the selected origin as `BASE_URL`; the plugin validates the fixed International/China origins and uses
`ctx.format.currency` for identity-only balance and deficit text. See [Moonshot](moonshot.md).

[`codexbar-plugin.d.ts`](../Sources/CodexBarCore/Resources/Plugins/codexbar-plugin.d.ts) is the canonical authoring
contract for `defineProvider`, the `ctx` host API, manifests, and usage snapshots. Bundled plugins may use that contract
directly as `.ts` sources. `Scripts/regenerate-plugin-js.sh` transpiles them with the vendored Sucrase build into
committed sibling `.js` files; the runtime continues to load only those JavaScript files, so bundled TypeScript has no
runtime compilation cost. `make check` verifies both the TypeScript contract and generated-file freshness.

For bundled-plugin work, run `make format` after editing TypeScript so the committed JavaScript is regenerated. Do not
edit a generated sibling `.js` file directly.

TypeScript files are transpiled by the selected plugin engine with the bundled Sucrase 3.35.1 build using its
`typescript` transform. Use ordinary
type syntax but no module imports, JSX, decorators, or runtime TypeScript features that require module resolution.
Transpiled output is cached in `~/Library/Caches/CodexBar/plugins/` under a filename containing the SHA-256 of the source
and the Sucrase version. An unchanged file is a cache hit; any source or compiler-version change produces a new key.
Transpile failures appear as that plugin's Settings error.

## Install, approve, run, and delete

1. Open **Settings → Plugins** and choose **Install…**, or copy one `.js`/`.ts` file into the providers directory.
2. CodexBar validates the source and manifest without network, file, cookie, or secret capabilities.
3. The approval sheet lists exact normalized origins, auth mode, capabilities, secure setting names, and cookie domains.
4. For loopback, IP-literal, or `.local` origins, type every normalized origin exactly before approval.
5. Enter manifest settings and enable the plugin. Its refresh result appears in its generic menu card.

Approval records live outside plugin files under `~/Library/Application Support/CodexBar/plugin-approvals.json`. A
change to instance ID, normalized origins, auth mode/header, secure setting names, capabilities, or cookie domains
invalidates approval before the next request. There is no bulk approval or import path.

Bundled first-party plugins do not use the interactive plugin-approval flow. The private-network HTTP policy is therefore
accepted for bundled code only for LLM Proxy, LiteLLM, Bifrost, and llmman, whose configured endpoints permit exactly those
targets. Other bundled providers fail manifest validation if they request that policy.

`codexbar plugins list` shows locally discovered plugins. `codexbar plugins fetch <id>` displays the same approval
fields and can approve only from an interactive terminal; redirected/headless input fails closed. Browser-cookie plugins
are app-only and fail closed in the CLI.

Every CLI command discovers user plugins before loading config, so `config providers` and `config dump` include
installed plugins. Unrelated app and CLI config writes preserve unavailable plugin records, including settings and
secrets, in their original positions. Missing files, discovery failures, and platforms without the plugin runtime do
not delete saved data. `config providers` labels these entries as `plugin (not loaded)`. Their opaque fields are
redacted in `config dump` unless `--show-secrets` is explicitly requested.
After discovery, entries using an unsupported future config format remain unchanged if an edit would lose data.

Delete from Settings with **Delete…**. CodexBar removes the plugin file, matching TypeScript cache output, approval,
per-instance settings and secrets, and per-instance usage history. Invalid plugin files are listed with their validation
error and can also be deleted.

## Security and limitations

Treat a plugin like code you run locally, even though its host capabilities are narrow. Read the manifest and source,
verify every origin, and avoid installing files from untrusted repositories. Approval grants the listed origin network
authority; DNS changes after approval are outside CodexBar's threat model. Secrets are never placed in URLs or logged,
redirects cannot forward authentication, and undeclared settings/cookies/origins fail closed.

Plugins support the macOS app plus the macOS and Linux CLIs. They are excluded from widgets and all built-in-provider-only
surfaces (status feeds, token accounts, OAuth, browser automation, storage probes, local cost scanners, and provider
specific payloads). Rendering is limited to generic snapshots and declarative details. There are no remote catalogs,
downloaded plugins/assets, custom SVGs, imports, arbitrary local I/O, or compatibility fallback from an unknown ID to a
built-in provider.

## Provider switcher tabs

Set `topLevel: true` in the manifest to give an enabled plugin its own tab when **Merge Icons** is enabled. The tab uses
the manifest name and icon. Selecting it shows that plugin’s usage followed by any enabled plugins using the original
appended-card placement. With Merge Icons disabled, plugins retain appended-card placement.

A single plugin works without a redundant switcher, and multiple plugin tabs work even with no built-in providers
enabled. Refresh and Cmd-R refresh the selected plugin; each card’s refresh button targets that card. Completed
refreshes update visible plugin cards, and repeated requests for the same plugin share its in-flight refresh.
Overview continues to summarize built-in providers. This setting changes placement only: it grants no additional host
capabilities and does not change network approval.

## Browser session cache

Bundled plugins that declare multiple cookie domains use separate Keychain-backed cache scopes for each requested
domain. Single-domain plugins retain their existing provider cache. Automatic imports query only the requested domain;
the default browser is Chrome, with existing provider browser-order overrides preserved. Manual headers bypass the
cache and browser import, and Off fails before either is accessed.

Call `ctx.browser.rejectCookie(domain)` after the server rejects a session. The host checks the declared domain and
evicts only the cached entry observed by that fetch (each domain is pinned for the fetch lifetime); a newer session and other domains remain intact. Manual headers
are never erased. User plugins have no persistent cookie cache, so rejection is a validated no-op for them.

## API balance bundled providers

[DeepInfra](deepinfra.md) uses its bundled script on both engines. It requires both billing GETs, preserves
prepaid-balance deductions and monthly cents conversion, and retries transient failures once. The Swift fetcher and
parser have been removed.

[ZenMux](zenmux.md) uses its bundled script on both engines. It requires subscription quotas and optionally enriches
them with USD PAYG balance; failed enrichment preserves quotas except for rejected credentials and cancellation. The
Swift fetcher and parser have been removed.

[Atlas Cloud](atlascloud.md) and [Vercel AI Gateway](vercel.md) use fixed-origin bearer GETs for documented
account/team balances. Their bundled JavaScript returns generic details without fabricated quota windows;
Swift provides registration and the shared API-key settings field. Scripts classify HTTP failures and the host bounds retries.

## GitKraken AI bundled provider

[GitKraken AI](gitkraken.md) uses bearer GET against its declared first-party API origin, with optional
organization scope and generic weekly windows/details. Swift supplies only registration and config projection.

## Charm Hyper bundled provider

[Charm Hyper](hyper.md) uses declared-domain cookies or a secure API key against its fixed credits endpoint.
The bundled TypeScript owns session preference, API fallback, error classification, and HC balance parsing;
Swift supplies registration and the shared settings surface.

## Zed bundled provider

[Zed](zed.md) uses its bundled script for editor API and opt-in browser billing requests. Swift retains editor settings
and Keychain credential discovery; browser mode uses a declared `zed.dev` cookie session and never reads editor credentials.
