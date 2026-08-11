---
summary: "All-provider conversion matrix for the bundled JavaScriptCore prototype capability set."
read_when:
  - Choosing another provider to convert to JavaScript
  - Planning the next plugin host capability
---

# Provider plugin conversion matrix

This matrix evaluates all 68 providers in the current capability audit against the prototype documented in
[`plugin-prototype.md`](plugin-prototype.md). Each provider has one primary blocker.

`convertible-now` means the canonical first-party flow is GET-only, uses a fixed HTTPS origin and header secret, and fits
the generic snapshot. Optional canonical-origin endpoint overrides do not change that bucket; providers whose identity
is inherently a user-chosen origin (LLM Proxy and LiteLLM) do not qualify. The convertible rows were checked against the
current Swift request methods and snapshot projections; Azure OpenAI, StepFun, and Warp were removed from the audit's
earlier “fully expressible” baseline because their current implementations issue POST requests.

`converted` means the bundled JavaScript conversion is present behind `CODEXBAR_JS_PROVIDERS=1`. `cut-over` means the
bundled script is the only JavaScriptCore implementation, with any retained native core serving Linux only. The Converted column
makes implementation state explicit and the totals are mutually exclusive: `convertible-now` counts only providers
that remain cheap to convert. Remaining buckets name the next blocker after this host-extension slice.

`needs-host-extension` means an existing native behavior cannot be represented without changing provider semantics or
weakening the plugin network policy.

## Totals

| Status | Count |
|---|---:|
| `cut-over` | 11 |
| `converted` | 5 |
| `convertible-now` | 10 |
| `needs-cookie-import` | 19 |
| `needs-files/subprocess/oauth-broker` | 15 |
| `needs-pty/webview/native` | 8 |
| `needs-host-extension` | 0 |
| **Total** | **68** |

## Matrix

| Provider | Status | Converted | Reason |
|---|---|:---:|---|
| codex | `needs-pty/webview/native` | No | PTY CLI, OAuth files/refresh, browser cookies, WKWebView scraping, local logs, and reset-credit details exceed this host. |
| openai | `converted` | Yes | Converted: fixed-origin bearer GET pagination with daily spend, model, line-item, and token details. |
| azureopenai | `needs-pty/webview/native` | No | The current quota probe is a POST chat completion against a user-configured deployment origin. |
| claude | `needs-files/subprocess/oauth-broker` | No | Full parity needs credential files/Keychain, OAuth refresh, CLI/PTY, cookies, local logs, and admin details. |
| fireworks | `convertible-now` | No | Identity can now carry the successful empty-billing state without inventing a rate window or cost. |
| clinepass | `cut-over` | Yes | Cut over on both engines: fixed-origin bearer GET, typed quota lanes, credential aliases, and classified failures match native behavior; the Swift fetcher and Linux fixtures are deleted. |
| cursor | `needs-cookie-import` | No | Browser cookies/app database provide auth, and integer request history also has bespoke detail. |
| opencode | `needs-cookie-import` | No | Skipped: React server-function response parsing needs a protocol-specific text decoder beyond `matchFirst`. |
| opencodego | `needs-files/subprocess/oauth-broker` | No | Local auth/SQLite state and browser sessions are required, with an additional bespoke usage model. |
| alibaba | `needs-cookie-import` | No | The console path needs imported cookies, CSRF/sec-token discovery, redirects, and embedded response parsing. |
| alibabatokenplan | `needs-cookie-import` | No | Full parity depends on Aliyun console cookies, CSRF/sec-token acquisition, and several dependent calls. |
| qwencloud | `needs-cookie-import` | No | Skipped: CSRF plus form POST and redirect-aware routing are not covered by JSON POST. |
| factory | `needs-cookie-import` | No | WorkOS/browser cookies and local storage recover the session; the API-key-only path is merely partial. |
| gemini | `needs-files/subprocess/oauth-broker` | No | Gemini CLI credential/config files, Google OAuth refresh, and a curl fallback own the current flow. |
| antigravity | `needs-pty/webview/native` | No | Process/port discovery, localhost IDE RPC, OAuth files, and a persistent PTY make this a native integration. |
| copilot | `needs-cookie-import` | No | API-token usage fits, but billing budgets require GitHub cookies/nonces and the device flow needs POST. |
| devin | `needs-files/subprocess/oauth-broker` | No | Full auth discovery reads Chromium localStorage and organization state; manual bearer alone is partial. |
| zai | `cut-over` | Yes | Cut over on both engines: regional and validated override endpoints, personal/team settings, quota lanes, model totals, and hourly/daily token charts; dashboard routing remains native and the fetch twin is deleted. |
| minimax | `needs-cookie-import` | No | Browser cookies/storage and group discovery feed a large service/billing/history-specific payload. |
| manus | `converted` | Yes | Converted: declared-domain cookie import, session-token extraction, JSON POST, and generic credit windows. |
| kimi | `needs-cookie-import` | No | Browser cookies plus Kimi credential/device files and regional identity headers exceed the current broker. |
| kilo | `needs-files/subprocess/oauth-broker` | No | The default source reads Kilo's local auth file and organization metadata. |
| kiro | `needs-pty/webview/native` | No | Usage exists only through bounded CLI pipe/PTY automation and a bespoke credit/overage model. |
| vertexai | `needs-files/subprocess/oauth-broker` | No | ADC/gcloud files, OAuth refresh, optional subprocess fallback, and local cost logs are required. |
| augment | `needs-files/subprocess/oauth-broker` | No | The preferred strategy spawns `auggie`; the alternative imports browser cookies and maintains sessions. |
| jetbrains | `needs-pty/webview/native` | No | There is no HTTP strategy; native IDE discovery and local XML parsing are the provider. |
| moonshot | `convertible-now` | No | Balance can remain intentionally identity-only, matching the native sparse snapshot. |
| amp | `needs-files/subprocess/oauth-broker` | No | CLI subprocess and browser-cookie strategies plus workspace credit details are outside this host. |
| t3chat | `converted` | Yes | Converted: declared-domain cookie import, JSONL text parsing, and generic base/overage windows. |
| ollama | `needs-cookie-import` | No | Skipped: hosted parity requires HTML bootstrap/state extraction plus API-key fallback arbitration. |
| synthetic | `cut-over` | Yes | Cut over on both engines: fixed-origin bearer GET with generic windows, cost, dates, and identity; the native fetch twin is deleted. |
| warp | `needs-pty/webview/native` | No | Warp sends a POST GraphQL operation, which the GET-only HTTP broker cannot express. |
| openrouter | `cut-over` | Yes | Cut over on both engines: endpoint and client-header overrides plus best-effort key enrichment are plugin-owned; the native fetch core is deleted. |
| elevenlabs | `convertible-now` | No | Verified `xi-api-key` GET; heterogeneous character/minute quotas map to named generic windows. |
| windsurf | `needs-files/subprocess/oauth-broker` | No | Chromium localStorage, IDE databases, and binary protobuf decoding supply the current session. |
| zed | `needs-files/subprocess/oauth-broker` | No | Zed server settings and a named Keychain credential must be read locally. |
| perplexity | `converted` | Yes | Converted: declared-domain cookie import and generic recurring, bonus, and purchased credit windows. |
| mimo | `needs-cookie-import` | No | Browser/Firefox session import and a local cache feed balance, plan, and token-specific details. |
| doubao | `needs-files/subprocess/oauth-broker` | No | Full parity needs a CLI subprocess or Volcengine HMAC signing and POST-based plan calls. |
| sakana | `needs-cookie-import` | No | Skipped: app-owned wiring and PAYG detail fixtures are outside the core descriptor seam. |
| abacus | `needs-cookie-import` | No | Skipped: exact calendar-month window parity needs a host date helper not in this slice. |
| mistral | `needs-cookie-import` | No | Skipped: CSRF discovery and dependent wallet, credit-note, and model-history calls exceed the minimal broker. |
| deepseek | `needs-files/subprocess/oauth-broker` | No | Platform auth/profile selection reads Chromium localStorage, and the result has a bespoke history model. |
| deepinfra | `convertible-now` | No | Verified fixed-origin bearer GET pair; spend limit and balance project into generic cost/windows. |
| codebuff | `needs-files/subprocess/oauth-broker` | No | Full credential parity reads a local Manicode credential file; environment-key mode is partial. |
| crof | `cut-over` | Yes | Cut over on JavaScriptCore: fixed-origin bearer GET with exact credit formatting and America/Chicago daily reset; native fetch code is Linux-only. |
| venice | `cut-over` | Yes | Cut over on JavaScriptCore: fixed-origin bearer GET with DIEM/USD allocation projection; native fetch code is Linux-only. |
| commandcode | `needs-cookie-import` | No | Skipped: live subscription/depletion flags lack reconstructable fixtures within the per-provider cap. |
| qoder | `converted` | Yes | Converted: declared global/China cookie domains, browser headers, and merged generic quota window. |
| stepfun | `needs-files/subprocess/oauth-broker` | No | Device registration, password login, refresh, quota, and plan operations are POST-based token-broker work. |
| bedrock | `needs-files/subprocess/oauth-broker` | No | AWS profiles/CLI credentials, SigV4 signing, pagination, and two services need host-owned credential/signing APIs. |
| grok | `needs-pty/webview/native` | No | Persistent stdio JSON-RPC, auth/session files, cookies, logs, and binary gRPC-web are strongly native. |
| groq | `needs-cookie-import` | No | Skipped: Stytch session exchange and console history remain a multi-step auth flow. |
| llmproxy | `convertible-now` | No | Settings origins now preserve native HTTPS/public and approved private-network HTTP behavior. |
| litellm | `convertible-now` | No | Settings origins now preserve native private-network HTTP behavior, and zero-spend identity-only snapshots are valid. |
| deepgram | `cut-over` | Yes | Cut over on JavaScriptCore: project discovery, aggregation, configured origins, numeric validation, and classified auth/permission/rate/network/API/parse failures match native behavior; the native fetch core is Linux-only. |
| poe | `cut-over` | Yes | Cut over on both engines: fixed-origin bearer GET balance/history pagination with daily points and model/type summaries; the native fetch twins are deleted. |
| chutes | `convertible-now` | No | Tolerant no-usage payloads can return an API identity without inventing quota data. |
| neuralwatt | `convertible-now` | No | Classified transient failures can request the same single delayed retry and capped `Retry-After` behavior as native. |
| clawrouter | `cut-over` | Yes | Cut over on JavaScriptCore: validated configured origins, classified failures, exact confidence, budget/ledger details, and provider charts match native behavior; the native fetch core is Linux-only. |
| longcat | `needs-cookie-import` | No | Skipped: browser-cookie retry needs domain/path-aware cookie selection across multiple imported sessions; the generic broker currently returns one flattened header. |
| sub2api | `cut-over` | Yes | Cut over on JavaScriptCore: configured HTTPS/loopback origins, a hard 15-second request deadline, strict parsing, exact confidence, and classified failures match native behavior; the native fetch core is Linux-only. |
| wayfinder | `needs-pty/webview/native` | No | The local unauthenticated HTTP gateway, metrics text, and routing/savings model violate HTTPS-only generic scope. |
| zenmux | `convertible-now` | No | Verified fixed-origin bearer GET pair; subscription and optional PAYG balance map generically. |
| aiand | `convertible-now` | No | An empty 30-day log window can omit unknowable currency and return its API identity. |
| zoommate | `needs-cookie-import` | No | Skipped: cookie-to-JWT exchange plus paginated history requires provider-specific retry state. |
| xai | `cut-over` | Yes | Cut over on both engines: bearer GET balance plus best-effort JSON POST history and billing details; the native fetch twins are deleted. |
| notion | `needs-cookie-import` | No | Workspace selection and AI allowance calls require imported Notion cookies and forwarded session headers. |
