---
summary: "Trae CN credit usage from its signed-in dashboard session."
provider_id: traecn
provider_name: Trae CN
provider_source: Browser session for account credit usage.
plugin_scope: Trae CN session token exchange and entitlement summary through the shared cookie broker.
---

# Trae CN

Trae CN is ByteDance's China-region service at [trae.cn](https://www.trae.cn). Enable **Trae CN** in
Settings → Providers after signing in to its dashboard. Automatic cookies use the shared browser order
and prompt policy. Manual mode accepts the Cookie header from an `api.trae.cn` dashboard request;
Off disables cookie access. No API key, endpoint override, or separate token store is needed.

The bundled plugin makes two non-billable requests to `https://api.trae.cn`:

1. `POST /cloudide/api/v3/common/GetUserToken` exchanges the browser session for a short-lived token.
2. `POST /trae/api/v2/pay/user_current_entitlement_list` reads the signed-in account's entitlement summary
   with `require_usage` and `full_data` enabled.

The exchanged token exists only during that refresh. It is not persisted and is never sent to another
origin. Rejected sessions permit the next browser candidate; transient failures retain the session.
Traversal stops at the first valid response. Refreshes do not send model prompts or purchase credits.

The primary gauge uses `usage_summary.consumed_amount / total_amount` across all credit packs.
Used, total, and remaining counts stay visible when the allowance is zero. Missing or invalid numbers
and non-credit billing fail closed instead of becoming zero usage.

Credit packs can expire independently. Pack expiry and billing-attempt timestamps do not establish a
single allowance reset or subscription renewal, so no countdown or monthly pacing window is inferred.
The active membership pack supplies the plan label.

This console API is reverse engineered and can change. Signed-out responses are classified as an
expired session; HTTP failures and response-format changes use the shared plugin error model.
