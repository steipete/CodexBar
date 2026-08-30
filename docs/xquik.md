---
summary: "Xquik API credit balance, lifetime usage, and CodexBar configuration."
read_when:
  - Configuring the Xquik provider
  - Reviewing Xquik credit parsing or authentication
---

# Xquik provider

CodexBar sends one non-mutating request to Xquik's free credit endpoint. It shows the exact available balance, lifetime usage, lifetime purchases, and automatic top-up state.

Xquik credits fund X automation. They are not a coding-model quota. CodexBar presents them as an account balance, not a reset window.

## Data source

1. Supply an account API key through `XQUIK_API_KEY` or Settings → Providers → Xquik. Settings values are stored in `~/.codexbar/config.json`.
2. CodexBar calls `GET https://xquik.com/api/v1/credits`.
3. The plugin sends the key through the `x-api-key` header.

The request does not consume credits. It never creates, updates, or deletes Xquik resources. The account key is not restricted to this credits request. Protect it like any account API key.

## Usage details

- The primary row shows the available Xquik credit balance.
- A funded balance renders as available. A zero balance renders as exhausted.
- The API does not return a credit ceiling. The bar therefore shows funded versus exhausted, not a fabricated percentage.
- Credit totals remain strings throughout parsing. This preserves values above JavaScript's safe integer range.
- The detail section shows available, lifetime used, and lifetime purchased credits.
- Automatic top-up details appear only when automatic top-up is enabled.
- Dashboard: `https://xquik.com`.
- API contract: `https://docs.xquik.com/api-reference/credits/get`.

## Related files

- `Sources/CodexBarCore/Resources/Plugins/xquik.js`
- `Sources/CodexBarCore/Providers/Xquik/`
- `Sources/CodexBar/Providers/Xquik/`
- `Tests/CodexBarTests/XquikProviderTests.swift`
