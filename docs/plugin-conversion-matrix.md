---
summary: "All-provider conversion matrix for the bundled JavaScriptCore prototype capability set."
read_when:
  - Choosing another provider to convert to JavaScript
  - Planning the next plugin host capability
---

# Provider plugin conversion matrix

This matrix evaluates 69 providers in the current capability audit against the prototype documented in
[`plugin-prototype.md`](plugin-prototype.md). Each provider has one primary blocker. This pass re-audits the remaining convertible and cookie rows;
other legacy classifications still need their own parity audit.

`convertible-now` means the canonical first-party flow fits the current HTTP GET/JSON POST, declared-origin,
authentication, and generic snapshot capabilities. Text decoding and dependent requests can be implemented in the
script. Settings-derived origins include the private-network HTTP policy for LLM Proxy and LiteLLM.

`converted` means the bundled conversion is present behind `CODEXBAR_JS_PROVIDERS=1`. `cut-over` means the script is
authoritative on its supported engines; each row states whether a Linux native core remains. Totals count only the
69 audit rows below, excluding the separately listed plugin-first additions.

`needs-cookie-import` now means **additional cookie/session capability**, not absence of cookie import. The current
broker imports declared domains, caches each domain separately (#3815), and offers policy-only
`ctx.browser.availability`. It now offers origin-bound candidate iteration and same-refresh advancement after rejection (#3933).
Remaining cookie rows need individual parity audits for their provider-specific ranking and recovery policies. Availability reports policy, not a validated browser login.
`needs-files/subprocess/oauth-broker` identifies native credential/storage flows beyond that broker.
`needs-host-extension` means another existing native behavior cannot be preserved with the current host APIs.

## Totals

| Status | Count |
|---|---:|
| `cut-over` | 28 |
| `converted` | 0 |
| `convertible-now` | 0 |
| `needs-cookie-import` | 7 |
| `needs-files/subprocess/oauth-broker` | 20 |
| `needs-pty/webview/native` | 8 |
| `needs-host-extension` | 6 |
| **Total** | **69** |

## Matrix

| Provider | Status | Converted | Reason |
|---|---|:---:|---|
| codex | `needs-pty/webview/native` | No | PTY CLI, OAuth files/refresh, browser cookies, WKWebView scraping, local logs, and reset-credit details exceed this host. |
| openai | `cut-over` | Yes | Both engines use the bundled script for Admin API history, project scoping, and legacy billing fallback; the allowlisted typed card preserves the native dashboard and source labels. Native fetchers are deleted. |
| azureopenai | `needs-pty/webview/native` | No | The current quota probe is a POST chat completion against a user-configured deployment origin. |
| claude | `needs-files/subprocess/oauth-broker` | No | Full parity needs credential files/Keychain, OAuth refresh, CLI/PTY, cookies, local logs, and admin details. |
| fireworks | `cut-over` | Yes | Both engines use the bundled script for account discovery and billing spend, including empty results, dynamic source labels, and allowlisted app/CLI slug persistence with save diagnostics. Native fetcher is deleted. |
| clinepass | `cut-over` | Yes | Cut over on both engines: fixed-origin bearer GET, typed quota lanes, credential aliases, and classified failures match native behavior; the Swift fetcher and Linux fixtures are deleted. |
| cursor | `needs-files/subprocess/oauth-broker` | No | Native app-auth SQLite discovery and local CSV usage remain required; domain cookies do not replace those sources. |
| opencode | `needs-cookie-import` | No | GET/JSON POST and SolidStart text decoding fit JavaScript, but cached-session rejection requires a same-refresh fresh cookie import. |
| opencodego | `needs-files/subprocess/oauth-broker` | No | Local auth/SQLite state and browser sessions are required, with an additional bespoke usage model. |
| alibaba | `needs-host-extension` | No | Console auth still requires form-encoded POST and CSRF/sec-token discovery; the host only sends JSON POST. |
| alibabatokenplan | `needs-host-extension` | No | Console requests require form-encoded POST and redirect-aware cookie forwarding, which domain-scoped headers do not supply. |
| qwencloud | `needs-host-extension` | No | CSRF plus form-encoded POST and redirect-aware routing remain outside the JSON-only POST broker. |
| factory | `needs-files/subprocess/oauth-broker` | No | The canonical fallback recovers WorkOS tokens from browser localStorage and persists sessions; cookie headers cover only part of auth. |
| gemini | `needs-files/subprocess/oauth-broker` | No | Gemini CLI credential/config files, Google OAuth refresh, and a curl fallback own the current flow. |
| antigravity | `needs-pty/webview/native` | No | Process/port discovery, localhost IDE RPC, OAuth files, and a persistent PTY make this a native integration. |
| copilot | `needs-files/subprocess/oauth-broker` | No | Full parity includes stored token discovery and interactive device authorization with form-encoded POST; billing cookies alone are insufficient. |
| devin | `needs-files/subprocess/oauth-broker` | No | Full auth discovery reads Chromium localStorage and organization state; manual bearer alone is partial. |
| zai | `cut-over` | Yes | Cut over on both engines: regional and validated override endpoints, personal/team settings, quota lanes, model totals, and hourly/daily token charts; dashboard routing remains native and the fetch twin is deleted. |
| minimax | `needs-files/subprocess/oauth-broker` | No | Full auth recovery includes browser localStorage and group/session state, beyond declared-domain cookie headers. |
| manus | `cut-over` | Yes | Both engines iterate rejected cached/browser sessions before environment fallback, preserving manual/off policy, JSON POST, sparse credits, and reset details. The native fetcher and cookie importer are deleted. |
| kimi | `needs-files/subprocess/oauth-broker` | No | Credential/device files and desktop token discovery remain native; domain cookies cover only the web account path. |
| kilo | `needs-files/subprocess/oauth-broker` | No | The default source reads Kilo's local auth file and organization metadata. |
| kiro | `needs-pty/webview/native` | No | Usage exists only through bounded CLI pipe/PTY automation and a bespoke credit/overage model. |
| vertexai | `needs-files/subprocess/oauth-broker` | No | ADC/gcloud files, OAuth refresh, optional subprocess fallback, and local cost logs are required. |
| augment | `needs-files/subprocess/oauth-broker` | No | The preferred strategy spawns `auggie`; the alternative imports browser cookies and maintains sessions. |
| jetbrains | `needs-pty/webview/native` | No | There is no HTTP strategy; native IDE discovery and local XML parsing are the provider. |
| moonshot | `cut-over` | Yes | Both engines use the bundled TypeScript plugin for regional bearer GET and identity-only balances, preserving USD/CNY rounding and negative zero. Swift resolves region-bound credentials; the native fetcher is deleted. |
| amp | `needs-files/subprocess/oauth-broker` | No | CLI subprocess and browser-cookie strategies plus workspace credit details are outside this host. |
| t3chat | `cut-over` | Yes | Both engines preserve the 60-second default web timeout (bounded to 90 seconds), safe captured cURL headers, JSONL parsing, and base/overage windows. The native fetcher and parser are deleted. |
| ollama | `needs-cookie-import` | No | HTML parsing and API-key arbitration fit scripts, but automatic auth tries multiple browser-session candidates and preserves browser access diagnostics. |
| synthetic | `cut-over` | Yes | Cut over on both engines: fixed-origin bearer GET with generic windows, cost, dates, and identity; the native fetch twin is deleted. |
| warp | `needs-pty/webview/native` | No | Legacy classification pending a separate parity audit: GraphQL JSON POST is now supported, so the former GET-only rationale no longer establishes a blocker. |
| openrouter | `cut-over` | Yes | Cut over on JavaScriptCore: endpoint and client-header overrides plus one-second best-effort key enrichment match native behavior; the native fetch core is Linux-only. |
| elevenlabs | `cut-over` | Yes | Cut over on both engines: xi-api-key GET, validated endpoint overrides, subscription/voice windows, reset dates, and safe current/legacy auth diagnostics; the Swift fetch twin is deleted. |
| windsurf | `needs-files/subprocess/oauth-broker` | No | Chromium localStorage, IDE databases, and binary protobuf decoding supply the current session. |
| zed | `cut-over` | Yes | Editor and opt-in browser billing HTTP/parsing run in the plugin on both engines. Swift retains editor settings and named Keychain credentials; manual browser billing also works on Linux. |
| perplexity | `cut-over` | Yes | Both engines use the bundled script for candidate retries, bare-token cookie names, chunk assembly, environment fallback, and recurring/bonus/purchased credit windows. Native fetching and projection are deleted. |
| mimo | `needs-files/subprocess/oauth-broker` | No | The canonical pipeline includes the file-based local usage fallback as well as browser sessions; cookies alone cannot preserve it. |
| doubao | `needs-files/subprocess/oauth-broker` | No | Full parity needs a CLI subprocess or Volcengine HMAC signing and POST-based plan calls. |
| sakana | `needs-host-extension` | No | HTML parsing and generic quota/PAYG details fit scripts, but native PAYG collection shares a 200 ms budget from primary start and cancels unfinished work. The host lacks bounded optional-request collection and per-request cancellation. |
| abacus | `needs-host-extension` | No | Billing duration subtracts one Calendar.current month; the host exposes daily resets but no calendar/month subtraction with timezone parity. |
| mistral | `needs-cookie-import` | No | CSRF extraction and dependent GETs fit scripts, but auth rejection iterates alternate browser profiles and preserves session selection. |
| deepseek | `needs-files/subprocess/oauth-broker` | No | Platform auth/profile selection reads Chromium localStorage, and the result has a bespoke history model. |
| deepinfra | `cut-over` | Yes | Both engines use fixed-origin bearer GETs for required billing data, preserving cents conversion, balance deductions, suspension, spending limits, and bounded retries. The native fetcher and parser are deleted. |
| codebuff | `needs-files/subprocess/oauth-broker` | No | Full credential parity reads a local Manicode credential file; environment-key mode is partial. |
| venice | `cut-over` | Yes | Cut over on JavaScriptCore: fixed-origin bearer GET with DIEM/USD allocation projection; native fetch code is Linux-only. |
| commandcode | `needs-host-extension` | No | Optional subscription enrichment races a two-second grace after required credits finish; per-request timeouts cannot preserve that join boundary. |
| qoder | `cut-over` | Yes | Both engines use the bundled script for regional candidate retries and merged quota parsing. Manual captures bind to one origin; Swift retains capture validation, settings, and source/dashboard presentation only. Native fetching is deleted. |
| stepfun | `needs-files/subprocess/oauth-broker` | No | Device registration, password login, refresh, quota, and plan operations are POST-based token-broker work. |
| bedrock | `needs-files/subprocess/oauth-broker` | No | AWS profiles/CLI credentials, SigV4 signing, pagination, and two services need host-owned credential/signing APIs. |
| grok | `needs-pty/webview/native` | No | Persistent stdio JSON-RPC, auth/session files, cookies, logs, and binary gRPC-web are strongly native. |
| groq | `needs-cookie-import` | No | Stytch JSON POST/JWT decoding fit scripts, but auth selects and retries merged browser-profile sessions; local-calendar history bounds also need parity proof. |
| llmproxy | `cut-over` | Yes | Cut over on both engines: configured HTTPS/private-network HTTP, quota-group variants, aggregate totals, provider summaries, and classified failures; the native fetch twin is deleted. |
| litellm | `cut-over` | Yes | Cut over on both engines: configured HTTPS/private-network HTTP, key-bound user/team lookups, budgets, spend-only and identity-only snapshots; the native fetch twin is deleted. |
| bifrost | `cut-over` | Yes | Bundled TypeScript on both engines: configured HTTPS/private-network HTTP, virtual-key header auth, budget overrides, reset-only rate limits, and numeric model/budget details. Swift owns registration and settings only. |
| deepgram | `cut-over` | Yes | Cut over on JavaScriptCore: project discovery, aggregation, configured origins, numeric validation, and classified auth/permission/rate/network/API/parse failures match native behavior; the native fetch core is Linux-only. |
| poe | `cut-over` | Yes | Cut over on both engines: fixed-origin bearer GET balance/history pagination with daily points and model/type summaries; the native fetch twins are deleted. |
| chutes | `cut-over` | Yes | Both engines use the bundled TypeScript plugin for subscription usage and best-effort quota enrichment, preserving empty snapshots and subscription context; the native fetcher is deleted. |
| helmcode | `cut-over` | Yes | Both tenant HTTP flows and quota projection live in the bundled TypeScript plugin, using domain-scoped cookies and policy-only availability. Swift supplies registration, settings, and dashboard routing. No native fetcher or cURL-capture fallback. |
| neuralwatt | `cut-over` | Yes | Cut over on both engines: validated configured HTTPS, subscription kWh, prepaid balance, key allowances, and exact confidence; the host preserves selective single retries, capped Retry-After, and cancellation. The native fetch twin is deleted. |
| clawrouter | `cut-over` | Yes | Cut over on JavaScriptCore: validated configured origins, classified failures, exact confidence, budget/ledger details, and provider charts match native behavior; the native fetch core is Linux-only. |
| longcat | `needs-cookie-import` | No | Still needs path/domain-aware cookie selection and retries across imported profiles; per-domain cache isolation does not expose those candidates. |
| sub2api | `cut-over` | Yes | Cut over on JavaScriptCore: configured HTTPS/loopback origins, a hard 15-second request deadline, strict parsing, exact confidence, and classified failures match native behavior; the native fetch core is Linux-only. |
| wayfinder | `needs-pty/webview/native` | No | The local unauthenticated HTTP gateway, metrics text, and routing/savings model violate HTTPS-only generic scope. |
| zenmux | `cut-over` | Yes | Both engines use fixed-origin bearer GETs for required subscription quotas and optional USD PAYG balance. Auth failures and cancellation remain fatal during enrichment; the native fetcher and parser are deleted. |
| aiand | `cut-over` | Yes | Both engines use the bundled TypeScript plugin for paired-cursor log pagination, exact decimal sums, partial confidence, and explicit empty windows without a guessed currency; the native fetcher is deleted. |
| zoommate | `needs-cookie-import` | No | Domain-scoped bootstrap GET/JWT exchange and history pagination fit scripts, but rejected sessions advance to the next browser profile in the same refresh. |
| xai | `cut-over` | Yes | Cut over on both engines: bearer GET balance plus best-effort JSON POST history and billing details; the native fetch twins are deleted. |
| notion | `needs-cookie-import` | No | Workspace JSON POST fits scripts, but legacy/current-domain cookie ranking, persisted session reuse, and immediate re-import on rejection exceed the header broker. |

## Additional plugin-first providers

| Provider | Status | Engines | Scope |
|---|---|---|---|
| gitkraken | `cut-over` | QuickJS + JavaScriptCore | First-party bearer GET, optional organization header, weekly personal/shared credits; API-only, no subprocess fallback. |
| hyper | `cut-over` | QuickJS + JavaScriptCore | Fixed-origin credits GET with Chrome/manual session preference and API-key fallback; native HC balance, no invented quotas or resets. |
| devpass | `cut-over` | QuickJS + JavaScriptCore | Documented bearer GET for billing-cycle and premium weekly credits plus separate all-time key spend; API-only. |
| atlascloud | `cut-over` | QuickJS + JavaScriptCore | Public billing API bearer GET for the account-wide available USD balance; no invented quota or Coding Plan allowance. |
| vercel | `cut-over` | QuickJS + JavaScriptCore | Public credits API bearer GET for team USD balance and lifetime spend; no CLI discovery or metered reporting. |
| llmman | `cut-over` | QuickJS + JavaScriptCore | Configured loopback/private-network daemon origin with an optional bearer key; `/llmman/node` memory and model summaries, best-effort version. |
