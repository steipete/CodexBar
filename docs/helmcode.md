---
summary: "Helmcode plugin: Cloud and NaN Builders sessions, model quotas, and prepaid balances."
read_when:
  - Setting up or changing the Helmcode provider
  - Debugging Helmcode tenant selection or quota parsing
---

# Helmcode

CodexBar reads the dashboard APIs for Helmcode Cloud and NaN Builders through a bundled TypeScript plugin. Inference
API keys do not provide dashboard quotas. Enable Helmcode in Settings → Providers, then sign in to the corresponding
dashboard in Chrome. The provider is disabled by default and is not widget-selectable.

| Tenant | Dashboard | API |
| --- | --- | --- |
| Helmcode Cloud | `https://cloud.helmcode.com/dashboard` | `https://cloud-api.helmcode.com` |
| NaN Builders | `https://cloud.nan.builders/dashboard` | `https://cloud-api.nan.builders` |

Automatic cookie source tries Cloud first, then NaN when no Cloud session is available or Cloud rejects it. A quota
parse error, rate limit, or server failure stops the refresh instead of switching accounts. Sessions are cached in
separate Keychain scopes by requested cookie domain; rejected sessions are conditionally evicted without erasing
another tenant or a newer session. The Usage Dashboard action follows the tenant of the displayed successful snapshot.

For Manual cookie source, paste the request's `Cookie:` header and choose **Manual cookie tenant**. The header is sent
only to that tenant, and never falls back to the other one. Cookie Off disables cookie access. Manual mode bypasses
browser imports and the automatic cache. There is no cURL-capture tenant detection or environment-cookie fallback.
CLI users can configure `cookieSource: "manual"`, `cookieHeader`, and `region: "helmcode" | "nanBuilders"` in their
provider config. API-only source policy cannot resolve browser cookies.

The plugin requests `/api/usage/quota` for model usage and `/api/billing` for premium eligibility. Only Cloud requests
`/api/billing/credits`; NaN has no prepaid balance. Requests carry the selected tenant's Cookie, Origin and Referer.
The complete cookie header is used for these endpoints. No endpoint rejection requiring request-path filtering has
been established; path-aware cookie filtering is outside this implementation.

Positive model caps become rate windows, ordered by utilization. Each model's `periodEnd` supplies its reset, falling
back to the first day of the month after `periodStart`. Rolling tiers retain `windowHours` as their window length and
appear only when billing explicitly reports `subscription.premium: true`. Missing, malformed, or unavailable billing
therefore hides premium tiers. Unlimited models have no invented percentage. Optional credit-funded tokens appear in
the detail text, and Cloud prepaid micros are converted to the reported currency (EUR when omitted).

Quota schema changes fail visibly. Quota requests have an eight-second deadline; billing and credits are best-effort
with two-second deadlines, so their failure cannot hide valid quota.
All identity and tenant fields come from this provider. The dashboard contract is unversioned; synthetic fixtures cover
both tenants, premium eligibility, per-model resets, optional billing failures, and malformed quota responses.
