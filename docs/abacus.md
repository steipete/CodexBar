---
summary: "Abacus AI provider: browser cookie auth for ChatLLM/RouteLLM compute credit tracking."
read_when:
  - Adding or modifying the Abacus AI provider
  - Debugging Abacus cookie imports or API responses
  - Adjusting Abacus usage display or credit formatting
---

# Abacus AI Provider

The Abacus AI provider tracks ChatLLM/RouteLLM compute credit usage via browser cookie authentication.

## Features

- **Monthly credit gauge**: Shows credits used vs. plan total with pace tick indicator.
- **Reserve/deficit estimate**: Projected credit usage through the billing cycle.
- **Reset timing**: Displays the next billing date from the Abacus billing API.
- **Subscription tiers**: Detects Basic and Pro plans.
- **Cookie auth**: Automatic browser cookie import (Safari, Chrome, Firefox) or manual cookie header.

## Setup

1. Open **Settings → Providers**
2. Enable **Abacus AI**
3. Log in to [apps.abacus.ai](https://apps.abacus.ai) in your browser
4. Cookie import happens automatically on the next refresh

### Manual cookie mode

1. In **Settings → Providers → Abacus AI**, set Cookie source to **Manual**
2. Open your browser DevTools on `apps.abacus.ai`, copy the `Cookie:` header from any API request
3. Paste the header into the cookie field in CodexBar

## How it works

Two API endpoints are fetched concurrently using browser session cookies:

- `GET https://apps.abacus.ai/api/_getOrganizationComputePoints` — returns `totalComputePoints` and `computePointsLeft` (values are in credit units, no conversion needed).
- `POST https://apps.abacus.ai/api/_getBillingInfo` — returns `nextBillingDate` (ISO 8601) and `currentTier` (plan name).

Cookie domains: `abacus.ai`, `apps.abacus.ai`. Session cookies are validated before use (anonymous/marketing-only cookie sets are skipped). Valid cookies are cached in Keychain and reused until the session expires.

The billing cycle window is set to 30 days for pace calculation.

## CLI

```bash
codexbar usage --provider abacusai --verbose
```

## Troubleshooting

### "No Abacus AI session found"

Log in to [apps.abacus.ai](https://apps.abacus.ai) in a supported browser (Safari, Chrome, Firefox), then refresh CodexBar.

### "Abacus AI session expired"

Re-login to Abacus AI. The cached cookie will be cleared automatically and a fresh one imported on the next refresh.

### "Unauthorized"

Your session cookies may be invalid. Log out and back in to Abacus AI, or paste a fresh `Cookie:` header in manual mode.

### Credits show 0

Verify that your Abacus AI account has an active subscription with compute credits allocated.
