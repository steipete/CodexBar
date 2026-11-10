---
summary: "Helmcode plugin: Cloud and NaN Builders sessions, credit plans, model quotas, and prepaid balances."
read_when:
  - Setting up or changing the Helmcode provider
  - Debugging Helmcode tenant selection or quota parsing
---

# Helmcode

CodexBar reads the dashboard APIs for Helmcode Cloud and NaN Builders through a bundled TypeScript plugin. Inference
API keys do not provide dashboard quotas. Enable Helmcode in Settings → Providers, then sign in to the corresponding
dashboard in a supported browser. Automatic import follows the shared browser order and access gate.
The provider is disabled by default and is not widget-selectable.

| Tenant | Dashboard | API |
| --- | --- | --- |
| Helmcode Cloud | `https://cloud.helmcode.com/dashboard` | `https://cloud-api.helmcode.com` |
| NaN Builders | `https://cloud.nan.builders/dashboard` | `https://cloud-api.nan.builders` |

Automatic cookie source tries Cloud first, then NaN when no Cloud session is available or Cloud rejects it. A quota
parse error, rate limit, or server failure stops the refresh instead of switching accounts. Sessions are cached in
separate Keychain scopes by requested cookie domain. Cloud first tries existing sessions under the previous
`helmcode.com` scope before using `cloud-api.helmcode.com` for current cached sessions and browser imports. If neither
works, it also imports parent-domain browser cookies from `helmcode.com`. NaN keeps its `nan.builders` scope. Rejected sessions are conditionally evicted
from the scope that supplied them without erasing another tenant or a newer session. The Usage Dashboard action follows the tenant of the displayed successful snapshot.
If browser access is suppressed or denied and neither tenant succeeds, the error explains how to retry permission
with Refresh in the provider menu or use Manual cookies. Background refreshes never request Keychain permission.

For Manual cookie source, paste the request's `Cookie:` header and choose **Manual cookie tenant**. The header is sent
only to that tenant, and never falls back to the other one. Cookie Off disables cookie access. Manual mode bypasses
browser imports and the automatic cache. There is no cURL-capture tenant detection or environment-cookie fallback.
CLI users can configure `cookieSource: "manual"`, `cookieHeader`, and `region: "helmcode" | "nanBuilders"` in their
provider config. API-only source policy cannot resolve browser cookies.

The plugin requests `/api/usage/quota` for model usage and `/api/billing` for premium eligibility. Only Cloud requests
`/api/billing/credits`; NaN has no prepaid balance. Requests carry the selected tenant's Cookie, Origin and Referer.
The complete cookie header is used for these endpoints. No endpoint rejection requiring request-path filtering has
been established; path-aware cookie filtering is outside this implementation.

NaN metered inference in credits from 10 November 2026, and `/api/usage/quota` kept answering with the per-model
token caps it had before the switch, frozen at the last legacy request. The plugin therefore asks
`/api/usage/credits` first; when the tenant reports `enabled: true` that plan replaces the token windows entirely. Its
allowance is credited per billing period rather than per calendar month, so the primary **Credits** window uses
`usedCredits / allowanceCredits` with the plan's own `periodEnd` as its reset, and carries the absolute allowance as
`quotaLimit`/`quotaUnit: "credits"`. Each model's `creditsThisMonth` and `approxCreditsPerMTokens` weight become detail
rows, and a purchased pack or a paused plan adds its own row. The window is labelled **Credits**; a tenant that answers
404 or `enabled: false` keeps the token quotas below and the `Model quota` label.

Positive model caps become rate windows, ordered by utilization. Each model's `periodEnd` supplies its reset, falling
back to the first day of the month after `periodStart`. Rolling tiers retain `windowHours` as their window length and
appear only when billing explicitly reports `subscription.premium: true`. Missing, malformed, or unavailable billing
therefore hides premium tiers. Unlimited models have no invented percentage. Optional credit-funded tokens appear in
the detail text, and Cloud prepaid micros are converted to the reported currency (EUR when omitted).

Quota and credit-plan requests have an eight-second deadline; billing is best-effort with a two-second deadline, so its
failure cannot hide valid quota. The credit plan is read before billing, which a credit-metered tenant does not need.
Because that plan decides the whole snapshot, only a 404 or `enabled: false` falls back to token quotas: a timeout, a
rate limit, a 5xx, or a 200 that omits the boolean `enabled` fails the refresh instead of republishing the frozen
windows. A plan with
nonnumeric or nonpositive totals fails as a parse error instead of rendering as an empty allowance.

All identity and tenant fields come from this provider. The dashboard contract is unversioned; synthetic fixtures cover
both tenants, premium eligibility, per-model resets, optional billing failures, credit metering, and malformed quota responses.

