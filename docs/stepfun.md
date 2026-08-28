---
summary: "StepFun provider data sources: username + password login for Step Plan rate limits and subscription plan name."
read_when:
  - Adding or tweaking StepFun rate limit parsing
  - Updating StepFun login flow
  - Documenting new provider behavior
---

# StepFun provider

StepFun (阶跃星辰) is a web-based provider. Usage data comes from the Step Plan rate limit API,
authenticated via an Oasis-Token obtained through a username + password login flow.

## Data sources

1. **Authentication** — Three methods (in priority order):
   - **Auto mode**: Username + password entered in Settings → Providers → StepFun.
     CodexBar performs a 3-step login flow to obtain an Oasis-Token:
       1. `GET https://platform.stepfun.com` → `INGRESSCOOKIE`
       2. `POST …/RegisterDevice` → anonymous token
       3. `POST …/SignInByPassword` → authenticated Oasis-Token
     The token is cached in Keychain-backed `CookieHeaderCache` and reused until it expires.
   - **Manual mode**: Paste an Oasis-Token directly in Settings → Providers → StepFun.
   - **Environment variables**: `STEPFUN_USERNAME` + `STEPFUN_PASSWORD`, or `STEPFUN_TOKEN`.

2. **Rate limit endpoint**
   - `POST https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit`
   - Request headers: `Cookie: Oasis-Token=<token>`, `Content-Type: application/json`
   - Response fields:
     - `five_hour_usage_left_rate` — remaining fraction for the 5-hour window (e.g. `0.99781543`)
     - `weekly_usage_left_rate` — remaining fraction for the weekly window
     - `five_hour_usage_reset_time` — reset timestamp (string or integer)
     - `weekly_usage_reset_time` — reset timestamp (string or integer)
     - `plan_family` — plan family identifier; `2` = credit-based subscription (e.g. Mini, Pro).
       For credit plans the rate-window fields above are `0` (no window configured).
     - `plan_credit_rate_limit` — credit usage object (present for `plan_family: 2`):
       - `subscription_credit_left_rate` — remaining subscription credit fraction (e.g. `0.9641`)
       - `subscription_credit_reset_time` — credit refill/reset timestamp
       - `topup_credit_left_rate` — remaining top-up credit fraction
       - `credit_buckets` — array of `{ credit_total, credit_residual, expire_at, next_reset_at }`

3. **Plan status endpoint**
   - `POST https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus`
   - Same auth headers as above
   - Response → `subscription.name` → plan name (e.g. "Plus", "Mini")
   - If this request fails, usage data is still displayed without a plan name.

## Usage details

- **Rate-window plans** (`plan_family` absent or ≠ 2):
  - **Primary window** (top bar): 5-hour rate limit (300 minutes).
  - **Secondary window** (bottom bar): weekly rate limit (10 080 minutes).
  - `usedPercent` is computed as `(1.0 - left_rate) × 100`.
- **Credit-based plans** (`plan_family: 2`, e.g. Mini, Pro):
  - **Primary window** (top bar): combined credit balance, weighted from `credit_buckets`
    residual/total values when available.
  - Without bucket sizes, uses `subscription_credit_left_rate` (or `topup_credit_left_rate` when
    no subscription rate exists); the independent percentages cannot be safely added.
  - No secondary window — credit plans don't have 5h/weekly rate-limit windows.
  - `usedPercent = (1.0 - credit_left_rate) × 100`.
- Plan name is shown as the `loginMethod` label in the menu card (e.g. "Plus").
- When auth source is set to **Off**, no background refreshes occur.
- Token expiry triggers automatic re-login (cache is cleared and the 3-step flow runs again).
- The `Oasis-Webid` header/cookie must match the token's `device_id` claim. For tokens obtained
  via Auto login the device_id is the app's own; for browser-imported (Manual) tokens it is
  derived from the refresh-token JWT payload.

## Key files

- `Sources/CodexBarCore/Providers/StepFun/StepFunProviderDescriptor.swift` (descriptor + web fetch strategy)
- `Sources/CodexBarCore/Providers/StepFun/StepFunUsageFetcher.swift` (login flow + HTTP client + JSON parser)
- `Sources/CodexBarCore/Providers/StepFun/StepFunSettingsReader.swift` (env var resolution)
- `Sources/CodexBar/Providers/StepFun/StepFunProviderImplementation.swift` (settings fields + activation logic)
- `Sources/CodexBar/Providers/StepFun/StepFunSettingsStore.swift` (SettingsStore extension)
- `Tests/CodexBarTests/StepFunUsageFetcherTests.swift` (26 test cases)
