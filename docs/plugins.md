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
- `endpoints`: 1–16 declared network origins. A fixed endpoint is a normalized HTTPS origin such as
  `https://api.example.com` (no path, query, fragment, or user info). A settings-derived endpoint is
  `{setting: "BASE_URL", policy: "https"}` or `{setting: "BASE_URL", policy: "https-or-loopback-http"}`. Its setting
  must be declared as `plain`. HTTP is allowed only for unauthenticated loopback targets.
- `auth` (optional): one of the forms below. The named secret must be a declared `secure` setting.
- `settings`: up to 32 setting definitions. Keys contain 1–64 ASCII letters, digits, or underscores and start with a
  letter. Each entry has `key`, `title`, optional `subtitle`, and `type: "plain" | "secure"` (default `secure`).
- `capabilities` (optional): currently only `"browser-cookies"`.
- `cookieDomains`: required with `browser-cookies`; a non-empty list of normalized DNS host names.
- `fetchUsage(ctx)`: function returning a snapshot object or a promise for one.

Authentication forms:

```js
auth: { type: "bearer", secret: "API_KEY" }
auth: { type: "x-api-key", secret: "API_KEY" }
auth: { type: "header", header: "X-Custom-Key", secret: "API_KEY" }
auth: { type: "authorization-scheme", scheme: "Token", secret: "API_KEY" }
```

The host owns the authentication header; plugin request options cannot override it. Authenticated origins must be
HTTPS. Secure settings can be overridden for CLI use with
`CODEXBAR_PLUGIN_<PLUGIN_ID>_<SETTING_KEY>`, uppercased with non-alphanumeric characters replaced by underscores. For
example, `acme-usage` and `API_KEY` use `CODEXBAR_PLUGIN_ACME_USAGE_API_KEY`.

## `ctx` API

`ctx` exists only during `fetchUsage`. JavaScriptCore provides ECMAScript built-ins but no browser or Node environment;
`fetch`, `XMLHttpRequest`, timers, `require`, `process`, and filesystem APIs are unavailable.

- `await ctx.http.getJSON(url, opts?)` performs GET and returns `{status, headers, json}`.
- `await ctx.http.get(url, opts?)` performs GET and returns `{status, headers, bodyText}`.
- `await ctx.http.postJSON(url, {body, headers?})` performs JSON POST. `body` must be JSON-serializable.
- `opts.headers` accepts string values. Plugins cannot replace their declared auth header.
- `ctx.settings.get(key)` reads a declared `plain` setting.
- `ctx.settings.getSecret(key)` reads a declared `secure` setting. Missing values return `null`; kind mismatches and
  undeclared keys throw.
- `await ctx.browser.cookieHeader(domain)` returns a cookie header only with the `browser-cookies` capability and for a
  declared domain. The app imports from Chrome only. Cookie values are secret-equivalent and redacted.
- `ctx.html.metaContent(html, name)` returns the first matching quoted meta value or `null`.
- `ctx.html.matchFirst(html, regexSource, flags?)` returns the first capture/full match or `null`.
- `ctx.log(...values)` writes to the instance-scoped plugin log. Known secrets and cookie values are redacted.
- `ctx.cache.get(key)` and `ctx.cache.set(key, value, ttlSeconds)` provide a per-runtime memory cache. TTL is capped at
  24 hours.
- `ctx.date.iso(text)`, `unixSeconds(number)`, and `unixMillis(number)` create JavaScript dates.
- `ctx.date.nextDailyReset(timeZoneIdentifier, hour)` returns the next wall-clock reset in an IANA time zone.
- `ctx.jwt.decode(token)` decodes (but does not authenticate) a JWT JSON payload.
- `ctx.pct(used, limit)` returns a finite percentage clamped to 0–100; non-positive limits map to 100.

User-plugin requests run in an ephemeral session with no ambient cookies, credential store, or URL cache. Redirects are
rejected, the timeout is 15 seconds, `Accept-Encoding: identity` is sent, compressed and non-2xx responses fail, and
response bytes are capped at 1 MiB. Request URLs must match a declared, approved origin.

## Snapshot result

Return at least one rate window, cost object, or detail section:

```js
return {
  primary: { usedPercent: 25, resetsAt: new Date(), windowMinutes: 300 },
  secondary: { usedPercent: 40, resetsAt: "2026-08-10T00:00:00Z", windowMinutes: 10080 },
  tertiary: { usedPercent: 5 },
  extraWindows: [{ id: "daily", title: "Daily", window: { usedPercent: 12 } }],
  cost: { used: 8.5, limit: 20, currency: "USD", period: "This month", balance: 11.5 },
  identity: { email: "user@example.com", organization: "Acme", loginMethod: "API key", accountID: "123" },
  subscriptionRenewsAt: "2026-09-01T00:00:00Z",
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
always scoped to the manifest's instance ID. Details allow at most 8 sections, 24 rows per section, 120 chart points,
and 120 characters per detail string. Wrong types and limit violations fail the whole fetch instead of truncating it.

## TypeScript

TypeScript files are transpiled with the bundled Sucrase 3.35.1 build using its `typescript` transform. Use ordinary
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

`codexbar plugins list` shows locally discovered plugins. `codexbar plugins fetch <id>` displays the same approval
fields and can approve only from an interactive terminal; redirected/headless input fails closed. Browser-cookie plugins
are app-only and fail closed in the CLI.

Delete from Settings with **Delete…**. CodexBar removes the plugin file, matching TypeScript cache output, approval,
per-instance settings and secrets, and per-instance usage history. Invalid plugin files are listed with their validation
error and can also be deleted.

## Security and limitations

Treat a plugin like code you run locally, even though its host capabilities are narrow. Read the manifest and source,
verify every origin, and avoid installing files from untrusted repositories. Approval grants the listed origin network
authority; DNS changes after approval are outside CodexBar's threat model. Secrets are never placed in URLs or logged,
redirects cannot forward authentication, and undeclared settings/cookies/origins fail closed.

Plugins support the macOS app and macOS CLI only. They are excluded from widgets and all built-in-provider-only
surfaces (status feeds, token accounts, OAuth, browser automation, storage probes, local cost scanners, and provider
specific payloads). Rendering is limited to generic snapshots and declarative details. There are no remote catalogs,
downloaded plugins/assets, custom SVGs, imports, arbitrary local I/O, or compatibility fallback from an unknown ID to a
built-in provider.

