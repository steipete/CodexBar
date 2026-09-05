---
summary: "Hugging Face provider: bearer-token spend and a separate browser-session prepaid Credits balance."
read_when:
  - Configuring Hugging Face usage or prepaid Credits
  - Debugging the Hugging Face billing-page wallet source
  - Reviewing Hugging Face spend versus wallet presentation
---

# Hugging Face Provider

CodexBar keeps Hugging Face reported spend and the prepaid **Credits** wallet as separate values. The existing API
source reports billing-period spend and category totals. The optional web source reads the personal wallet shown by
[Hugging Face Billing](https://huggingface.co/settings/billing).

## Setup

1. Open **Settings -> Providers** and enable **Hugging Face**.
2. Configure a Hugging Face user access token, set `HF_TOKEN` or `HUGGING_FACE_HUB_TOKEN`, or run `hf auth login`
   for API-reported spend. File-based CLI credentials follow `HF_TOKEN_PATH`, `HF_HOME/token`,
   `XDG_CACHE_HOME/huggingface/token`, and then `~/.cache/huggingface/token`.
3. To show the prepaid wallet, leave **Cookie source** on **Automatic** after signing in to Hugging Face in a
   supported browser, or select **Manual** and paste a full `Cookie:` header from `huggingface.co/settings/billing`.
4. Select **Off** to disable billing-page cookie access while retaining the API source.

The web source can show a balance without an API token. Automatic cookie import is limited to `huggingface.co` and
uses CodexBar's shared cached-cookie/browser-import path. Ordinary refresh does not open a browser or prompt for
Keychain access. Use **Open Hugging Face Billing** from Settings when a fresh authenticated session is needed. When an
API token is configured, ordinary Auto refresh reports API billing only; use the Cookie source **Refresh** action to
explicitly re-import and validate a browser wallet.

## Data sources

For a fine-grained token, Hugging Face may require the **Billing read** permission for the personal billing usage
endpoint. Invalid or expired tokens and transient rate limits are reported with provider-specific diagnostics.

- `GET https://huggingface.co/api/settings/billing/usage` with the bearer token reports billing-period spend and
  category totals. This is not the prepaid wallet.
- `GET https://huggingface.co/api/whoami-v2` supplies optional account identity and PRO-plan detail. It is cached
  in memory for 12 hours per token; billing spend is fetched on every refresh and remains authoritative.
- `GET https://huggingface.co/settings/billing` with a normal authenticated Hugging Face web session returns HTML
  containing server-rendered `div[data-props]` data. CodexBar reads the personal entity's `currentBalanceUsd` value as
  the prepaid wallet.

The current wallet field is already a finite, non-negative USD number. `$0.00` and fractional cents are valid. When
the current field is absent, CodexBar accepts the legacy top-level `invoiceCreditsCents` field only as a finite,
non-negative, JavaScript-safe integer and converts it from cents exactly once. It does not use visible page text,
`includedNanoUsd`, `usedNanoUsd`, `limitNanoUsd`, plan entitlements, or reported spend to derive a wallet balance.

Hugging Face does not currently expose a verified shared account identifier across the bearer-token and browser-session
paths. CodexBar therefore never composes those paths into one snapshot: an independently authenticated browser wallet is
never attached to an API billing snapshot, and CodexBar does not invent or compare an identifier from unverified
billing-page fields.

## Display and source modes

- **Auto** uses bearer-token billing whenever an API credential is available and returns that API result alone; it
  never queries browser cookies or merges an independently authenticated wallet into the API snapshot. Optional usage
  does not re-enable that combination. When no API credential is available, Auto can return a web-only wallet result
  if billing cookies are enabled.
- **API** uses the bearer-token spend path and never looks up cookies or requests the billing page.
- **Web** requests only the billing page and returns a balance-only snapshot. It does not request bearer spend or attach
  an account identity from the billing entity.
- **Cookie source Refresh** is an explicit browser-session validation action. Even when an API token is configured, it
  imports and validates the browser wallet through the Web source alone. It does not imply that ordinary Auto refreshes
  merge wallet data into API billing; ordinary Auto with an API credential remains API-only.

The provider Balance layout token and the provider balance row show the reported prepaid wallet. Hugging Face
Inference usage remaining and billing-period spend are separate concepts and are never substituted for Credits.

## Troubleshooting

### "No Hugging Face session cookies found"

Sign in to Hugging Face, open the billing page, and refresh. If automatic import is unavailable, switch to **Manual**
and paste a full `Cookie:` header for `huggingface.co`.

### The wallet is missing but spend is shown

With an API credential configured, Auto reports API billing alone and never merges a browser wallet, so the Credits
wallet is absent from an API-mode or API-preferred Auto snapshot by design. Use **Web** mode, or use the Cookie source
**Refresh** action after signing in to Hugging Face in the browser, to validate and show the prepaid wallet. A
missing/expired session, login redirect, non-HTML response, or malformed server-rendered payload makes a Web refresh
fail and keeps the previous cached cookie.

### The wallet shows `$0.00`

That is a valid reported zero balance, distinct from an unavailable or malformed wallet response.

## Related files

- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWebCreditsParser.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWebFetchStrategy.swift`
- `Sources/CodexBar/Providers/HuggingFace/HuggingFaceProviderImplementation.swift`
- `Tests/CodexBarTests/HuggingFaceUsageStatsTests.swift`
