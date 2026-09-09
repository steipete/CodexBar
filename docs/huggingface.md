---
summary: "Hugging Face provider: bearer-token spend plus the browser-session prepaid Credits wallet, gated by private identity matching."
read_when:
  - Configuring Hugging Face usage or prepaid Credits
  - Debugging the Hugging Face billing-page wallet source
  - Reviewing Hugging Face spend versus wallet presentation
---

# Hugging Face Provider

CodexBar shows Hugging Face reported spend and the prepaid **Credits** wallet together whenever both
authorities are safely available. The API source reports billing-period spend and category totals.
The web source reads the personal wallet shown by
[Hugging Face Billing](https://huggingface.co/settings/billing).

## Setup

1. Open **Settings -> Providers** and enable **Hugging Face**.
2. Configure a Hugging Face user access token, set `HF_TOKEN` or `HUGGING_FACE_HUB_TOKEN`, or run `hf auth login`
   for API-reported spend. File-based CLI credentials follow `HF_TOKEN_PATH`, `HF_HOME/token`,
   `XDG_CACHE_HOME/huggingface/token`, and then `~/.cache/huggingface/token`.
3. To show the prepaid wallet, leave **Cookie source** on **Automatic** after signing in to Hugging Face in a
   supported browser, or select **Manual** and paste a full `Cookie:` header from `huggingface.co/settings/billing`.
4. Select **Off** to disable billing-page cookie access while retaining the API source.

Automatic cookie import is limited to `huggingface.co` and uses CodexBar's shared cached-cookie/browser-import
path. Ordinary refresh does not open a browser or prompt for Keychain access. Use **Open Hugging Face Billing**
from Settings when a fresh authenticated session is needed, or the Cookie source **Refresh** action to
explicitly re-import and validate a browser wallet.

## Data sources

For a fine-grained token, Hugging Face may require the **Billing read** permission for the personal billing usage
endpoint. Invalid or expired tokens and transient rate limits are reported with provider-specific diagnostics.

- `GET https://huggingface.co/api/settings/billing/usage` with the bearer token reports billing-period spend and
  category totals. This is not the prepaid wallet.
- `GET https://huggingface.co/api/whoami-v2` is owned by CodexBar's Swift-side Hugging Face identity service for
  both authorities (bearer token and browser session cookie). It supplies optional display identity and the
  private opaque `id` used for cross-authority matching; the plugin no longer performs identity requests.
- `GET https://huggingface.co/settings/billing` with a normal authenticated Hugging Face web session returns HTML
  containing server-rendered `div[data-props]` data. CodexBar reads the personal entity's `currentBalanceUsd` value as
  the prepaid wallet.

The current wallet field is already a finite, non-negative USD number. `$0.00` and fractional cents are valid. When
the current field is absent, CodexBar accepts the legacy top-level `invoiceCreditsCents` field only as a finite,
non-negative, JavaScript-safe integer and converts it from cents exactly once. It does not use visible page text,
`includedNanoUsd`, `usedNanoUsd`, `limitNanoUsd`, plan entitlements, or reported spend to derive a wallet balance.

## Identity matching

Ownership proof uses only exact equality of the private opaque `whoami-v2` user `id`, requiring `type == "user"`.
Billing HTML `entity.name`, `entity.user`, email, organization membership, and balance values are never ownership
proof. Successful identities are cached in memory for 12 hours per credential fingerprint
(`CookieHeaderCache.credentialFingerprint`); raw tokens and cookie headers never appear in cache keys, logs, or
snapshots, and the opaque matching ID is never persisted or displayed.

## Display and source modes

- **Auto** is dual-source. API billing stays authoritative; the browser wallet is retrieved as auxiliary product
  data whenever browser access is safely available — independent of the generic optional-usage setting. On an exact
  identity match the wallet composes onto the API snapshot (`api+web`), with `balanceUpdatedAt` carrying the browser
  observation time. On mismatch or unverifiable identity the API snapshot stays unmodified and the wallet renders
  once at provider level, labeled as browser-session data with account ownership unverified. Browser identity is
  probed only after a successful wallet fetch, so token-only refreshes never perform browser matching work.
- **API** uses the bearer-token spend path and never looks up cookies or requests the billing page. Selecting it
  clears any provider-level wallet observation, even if the API request later fails.
- **Web** requests only the billing page and returns a balance-only snapshot. It does not request bearer spend or
  attach an account identity from the billing entity.
- **Cookie source Refresh** validates the Web wallet first and commits the staged cookies; a best-effort ordinary
  Auto refresh then restores the composed snapshot immediately. A broken API credential never turns a successful
  Cookie Refresh into failure or removes the wallet.

A stacked batch (multiple token accounts in the app or `codexbar --all-accounts`) observes the browser wallet once:
exactly one identity-matched account keeps the composed balance, multiple matches strip every composition and render
one provider-level wallet ("matches multiple API token accounts"), and zero matches render it as unverified. The
provider-level wallet also renders once in the compact multi-account menu, and the live card carries it even when no
API base snapshot exists. A failed Auto/API refresh that displaced a validated Web-owned snapshot keeps the wallet
visible once as browser-session data; a failed Web refresh never duplicates it into auxiliary state.

The provider Balance layout token and the provider balance row show the identity-matched prepaid wallet. Hugging Face
Inference usage remaining and billing-period spend are separate concepts and are never substituted for Credits.

## Troubleshooting

### "No Hugging Face session cookies found"

Sign in to Hugging Face, open the billing page, and refresh. If automatic import is unavailable, switch to **Manual**
and paste a full `Cookie:` header for `huggingface.co`.

### The wallet is missing but spend is shown

The wallet shows only when a browser session is safely available and its observation succeeds. A
missing/expired session, login redirect, non-HTML response, or malformed server-rendered payload makes the wallet
attempt fail and clears any previously shown provider-level wallet, so stale Credits are never presented as current.
Check the Cookie source, or use the Cookie source **Refresh** action after signing in to Hugging Face in the browser.

### The wallet shows `$0.00`

That is a valid reported zero balance, distinct from an unavailable or malformed wallet response.

## Related files

- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceIdentity.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWalletBatchScope.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWebCreditsParser.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWebFetchStrategy.swift`
- `Sources/CodexBar/Providers/HuggingFace/HuggingFaceProviderImplementation.swift`
- `Tests/CodexBarTests/HuggingFaceUsageStatsTests.swift`
