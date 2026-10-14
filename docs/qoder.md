---
summary: "Qoder provider: browser/manual cookie setup for big model credit usage on qoder.com and qoder.com.cn."
read_when:
  - Configuring Qoder usage
  - Debugging Qoder cookie import, manual headers, or cURL captures
  - Adjusting Qoder credit display
---

# Qoder Provider

CodexBar reads Qoder big model credit usage from the Qoder account dashboard. It supports the international
`qoder.com` site and the China mainland `qoder.com.cn` site.

## Setup

1. Open **Settings -> Providers**.
2. Enable **Qoder**.
3. Sign in to [qoder.com](https://qoder.com/account/usage) or [qoder.com.cn](https://qoder.com.cn/account/usage) in
   a supported browser.
4. Leave Cookie source on **Automatic**, or switch to **Manual**. For `qoder.com`, paste a `Cookie:` header or a cURL/
   HTTP request capture from the usage page. For `qoder.com.cn`, paste a request capture that includes the China URL
   or `Host` header so CodexBar can select the matching site.

Bare `Cookie:` headers default to `qoder.com`. Request captures are parsed only when the target URL or header host
clearly belongs to `qoder.com` or `qoder.com.cn`.
The settings snapshot binds the manual credential to that origin before normalizing its header. A China capture is
never offered to the global endpoint, and a rejected plain header is never retried against China. Existing plain
headers retain the global default; no config rewrite is needed.

## Data Source

CodexBar requests:

- `GET https://qoder.com/api/v2/me/usages/big_model_credits`
- `GET https://qoder.com.cn/api/v2/me/usages/big_model_credits`

The selected site controls the `Origin` and `Referer` headers. Automatic mode imports Qoder cookies in the shared browser order
and caches valid cookie headers. Invalid cached sessions are skipped so a fresh browser cookie can be retried.
The bundled JavaScript provider performs HTTP requests and quota parsing on both QuickJS and JavaScriptCore. Browser
profiles are tried in order with separate caches for each domain. The successful candidate's source and site are kept
for the source label and usage-dashboard action.

## Display

- Shows used credits, total credits, and usage percentage.
- Merges `totalQuota` with `sharedQuota` when Qoder returns both.
- Uses `nextResetAt` when the API includes a reset timestamp.
- Token-cost history is not supported.

## CLI Usage

```bash
codexbar usage --provider qoder --verbose
```

## Troubleshooting

### "Qoder session cookie not found"

Sign in to Qoder in a supported browser, then refresh CodexBar. If browser import is unavailable, switch to manual mode. Paste a
fresh `Cookie:` header for `qoder.com`; for `qoder.com.cn`, paste a cURL/HTTP request capture containing the China URL
or `Host` header.

### "Qoder session is invalid or expired"

Log in to Qoder again. CodexBar clears invalid cached cookies and retries fresh browser cookies in automatic mode.

### Usage values look wrong

Open the matching Qoder usage page and confirm whether the account is on `qoder.com` or `qoder.com.cn`; manual cURL
captures should come from the same site.

## Related Files

- `Sources/CodexBarCore/Providers/Qoder/QoderProviderDescriptor.swift`
- `Sources/CodexBarCore/Resources/Plugins/qoder.js`
- `Sources/CodexBarCore/Providers/Qoder/QoderCookieRouting.swift`
- `Sources/CodexBarCore/Plugins/ProviderPluginCookieBroker.swift`
- `Sources/CodexBar/Providers/Qoder/QoderProviderImplementation.swift`
