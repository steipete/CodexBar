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

When the member response reports no merged member quota (the Teams case), CodexBar also requests:

- `GET https://qoder.com/sash/api/v2/me/usage`
- `GET https://qoder.com.cn/sash/api/v2/me/usage`

The supplemental response carries the member-visible `orgResourcePackage` and, when present, `addOnQuota`, plus
`expiresAt` / `refreshAt` for the plan refresh. The supplemental request is optional: 401, 403, 404, malformed, or
unsupported responses fall back to the member summary without invalidating the cached cookie. The empty merged member quota gate is
Phase 1 coverage for the captured Teams account; always fetching the supplemental response for non-empty plans is a
follow-up.

The selected site controls the `Origin` and `Referer` headers. Automatic mode imports Qoder cookies in the shared browser order
and caches valid cookie headers. Invalid cached sessions are skipped so a fresh browser cookie can be retried.
The bundled JavaScript provider performs HTTP requests and quota parsing on both QuickJS and JavaScriptCore. Browser
profiles are tried in order with separate caches for each domain. The successful candidate's source and site are kept
for the source label and usage-dashboard action.

## Display

- Shows the member credit window as `Plan credits`, or `Credits` when the legacy `totalQuota` + `sharedQuota` aggregate is used.
- Shows the organization resource package and personal add-on credits as separate, distinctly named windows.
- A zero-capacity plan is shown as exhausted rather than fully available.
- Merges `totalQuota` with `sharedQuota` for the legacy member response.
- Uses the supplemental `expiresAt` / `refreshAt` when available; otherwise uses `nextResetAt`.
- Skips the optional supplemental request when the runtime deadline is too close, so a supplemental timeout cannot discard the member snapshot.
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

### Teams resource package is missing

Confirm the signed-in Teams account shows a resource package under **Settings -> Usage**. CodexBar requests the
supplemental usage presentation only when the merged member quota is empty; if that request fails, it keeps the member summary.

## Related Files

- `Sources/CodexBarCore/Providers/Qoder/QoderProviderDescriptor.swift`
- `Sources/CodexBarCore/Resources/Plugins/qoder.js`
- `Sources/CodexBarCore/Providers/Qoder/QoderCookieRouting.swift`
- `Sources/CodexBarCore/Plugins/ProviderPluginCookieBroker.swift`
- `Sources/CodexBar/Providers/Qoder/QoderProviderImplementation.swift`
