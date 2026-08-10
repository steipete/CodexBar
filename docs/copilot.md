---
summary: "Copilot provider data sources: GitHub device flow, Copilot internal usage API, and optional GitHub web budgets."
read_when:
  - Debugging Copilot login or usage parsing
  - Updating GitHub OAuth device flow behavior
---

# Copilot provider

Copilot uses GitHub OAuth device flow and the Copilot internal usage API for primary usage. Optional budget extras use GitHub web cookies only when enabled.

## Data sources + fallback order

1) **GitHub OAuth device flow** (user initiated)
   - Device code request:
     - `POST https://github.com/login/device/code`
   - Token polling:
     - `POST https://github.com/login/oauth/access_token`
   - Optional enterprise host:
     - set Copilot `enterpriseHost` in `~/.codexbar/config.json` or the provider settings UI
     - CodexBar normalizes values such as `https://octocorp.ghe.com/login` to `octocorp.ghe.com`
     - device flow uses `https://<enterpriseHost>/login/...`
   - Scope: `read:user`.
   - Token stored in config:
     - `~/.codexbar/config.json` → `providers[].apiKey` for `copilot`
     - token accounts use `providers[].tokenAccounts`

2) **Usage fetch**
   - `GET https://api.github.com/copilot_internal/user`
   - With an enterprise host, the API host is `api.<enterpriseHost>`.
   - Headers:
     - `Authorization: token <github_oauth_token>`
     - `Accept: application/json`
     - `Editor-Version: vscode/1.96.2`
     - `Editor-Plugin-Version: copilot-chat/0.26.7`
     - `User-Agent: GitHubCopilotChat/0.26.7`
     - `X-Github-Api-Version: 2025-04-01`

3) **Budget fetch** (optional GitHub web endpoint, best-effort)
   - Disabled by default. The Copilot provider's "Budget extras" setting must be enabled before CodexBar imports
     github.com cookies or renders budget bars.
   - CodexBar asks the logged-in GitHub web endpoint for customer-scope budgets:
     - `GET https://github.com/settings/billing/budgets?page=<page>&page_size=10&scope=customer`
   - Headers:
     - `Cookie: <github.com browser cookies>`
     - `Accept: application/json`
     - `X-Requested-With: XMLHttpRequest`
     - `GitHub-Verified-Fetch: true`
     - `X-Fetch-Nonce: <fresh nonce when available>`
   - CodexBar first tries to read a fresh nonce from `https://github.com/settings/billing/budgets`, then calls the JSON
     endpoint. If GitHub rejects the web request, CodexBar keeps the normal Copilot quota bars and omits budget bars.
   - This is intentionally not the public GitHub REST billing API. The REST API did not expose the personal budget list
     for the tested individual account.

## Snapshot mapping
- Primary: `quotaSnapshots.premiumInteractions` percent remaining → used percent.
- Secondary: `quotaSnapshots.chat` percent remaining → used percent.
- Extra: positive Copilot billing budgets from the GitHub web endpoint → `extraRateWindows`, only when "Budget extras"
  is enabled.
  - Product budget: `copilot`
  - SKU budgets: `copilot_premium_request`, `copilot_agent_premium_request`, `spark_premium_request`
- Seat AI credits: `quota_snapshots.premium_interactions.credits_used` → the shared "Credits used" provider-detail
  row, shown only when it carries real signal (token-based billing, unlimited quota, nonzero credits, or a
  configured seat entitlement) so a metered Pro/Individual seat never grows a permanent "0 credits used" row.
  Deliberately not summed with `chat`/`completions` credits — GitHub can report the same pool under multiple
  snapshot keys, and summing would double-count.
- Reset dates are not provided by the API.
- Plan label from `copilotPlan`.

## AI credit entitlements
GitHub does not publish an included-credit entitlement on any documented endpoint — all 8 billing endpoints plus
`budgets`, `cost-centers`, and `usage/summary` were probed, and none returns a ceiling for the seat. The denominator
is therefore user-entered:
- Preferences → Providers → Copilot → "Included AI credits (per seat)"

A configured entitlement turns the row into a progress bar ("31 / 3000") via the shared provider-detail row's
optional progress ratio. Without one, the row stays plain text, because a bar would imply a limit CodexBar cannot
actually know. Either way the row also carries the numeric credits used (`usageValue`), so editing or clearing
the entitlement rewrites the cached row (text ↔ bar) immediately, even when the follow-up refresh never lands
(offline, token lost, 401).

## Key files
- `Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Copilot/CopilotDeviceFlow.swift`
- `Sources/CodexBarCore/Providers/Copilot/CopilotCreditEntitlementParser.swift`
- `Sources/CodexBar/Providers/Copilot/CopilotLoginFlow.swift`
- `Sources/CodexBar/CopilotTokenStore.swift` (legacy migration helper)
