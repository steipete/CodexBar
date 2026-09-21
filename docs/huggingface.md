---
summary: "Hugging Face authentication and Inference Providers credit tracking."
read_when:
  - Configuring Hugging Face in CodexBar
  - Debugging Hugging Face token or billing permission errors
  - Adding or tweaking Hugging Face usage parsing
---

# Hugging Face

CodexBar shows month-to-date Inference Providers charges and optional ZeroGPU quota. Billing details include
billable usage, reported gross/included amounts, and a configured spending limit when available. The billing
report does not establish a remaining-credit allowance or quota reset, so CodexBar does not invent either.
The prepaid/general compute-credit wallet appears separately under **Credits** when an eligible browser session
can be verified as belonging to the same account as the API token.
Identity (username and PRO/Free plan) comes from `whoami-v2`, cached for hours because Hugging Face rate-limits that
endpoint far more strictly than the rest of the Hub API.

The bundled `huggingface.ts` plugin owns every HTTP request and response projection. Native code reads the existing
CLI token and serializes access to the retained script runtime. Identity caching lasts up to 12 hours and is keyed by
the selected token, so switching accounts cannot reuse another account's identity.

## Authentication

Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), then add it in
CodexBar's provider settings or token accounts, or set:

```bash
export HF_TOKEN="your-access-token"
```

Token sources, in precedence order: CodexBar settings (`CODEXBAR_HUGGINGFACE_API_KEY`), `HF_TOKEN`,
`HUGGING_FACE_HUB_TOKEN`, then the token saved by `hf auth login` (`$HF_TOKEN_PATH`, `$HF_HOME/token`,
`$XDG_CACHE_HOME/huggingface/token`, or `~/.cache/huggingface/token`).

Classic `read` tokens can read billing. Fine-grained tokens must have the **Billing read** permission or the billing
endpoints return HTTP 403, which CodexBar surfaces with a pointer to this requirement.

## Data shown

- Inference charges calculated as `max(0, usedNanoUsd - includedNanoUsd)`, matching Hugging Face's billing UI.
- Reported gross/included inference amounts and the configured spending limit, when present.
- ZeroGPU GPU-time used/remaining and its reset, when the account has ZeroGPU quota.
- Username and plan (PRO/Free).
- Prepaid Credits balance, including a reported zero, when the browser and token identities match.

## Endpoint contract

The billing endpoint (`/api/settings/billing/usage-v2`) is listed in Hugging Face's OpenAPI spec, but its response
shape is not documented. CodexBar parses it defensively and reports a clear "response format changed" error if the
shape drifts instead of showing partial data. ZeroGPU quota and `whoami-v2` are fully documented endpoints and are
fetched best-effort — their failures preserve billing data.

Live verification confirmed `periodEnd` follows the requested `endDate`: it is the report cutoff, not a reset.
The public billing frontend deducts `includedNanoUsd` to calculate the charge; this does not establish monthly
credits remaining. PRO compute credits are shared with other products, so `isPro` does not imply an inference-only allowance.

## Prepaid Credits wallet

In Auto mode, the plugin checks browser-cookie eligibility before resolving a session for `huggingface.co`.
It uses the shared cookie broker, then reads `/settings/billing` and verifies the same cookie with a separate
`/api/whoami-v2` request that carries no bearer token. Both identities must be users with exactly matching opaque
user IDs; display names and email addresses are not ownership evidence. The opaque ID stays in the plugin's
in-memory identity cache and is not included in the displayed account identity.

Only server-rendered billing `div` `data-props` are parsed: `entity.currentBalanceUsd` takes precedence over the
legacy `invoiceCreditsCents` value, which is converted from cents once. Missing, malformed, ambiguous, unavailable,
or mismatched wallet data is omitted while API usage remains visible. The balance has no inferred percentage,
allowance, or reset; it appears as a Credits detail section and as `providerCost.balance` in snapshot output.

Explicit API mode (`codexbar usage --provider huggingface --source api`) never resolves cookies or requests the
browser billing page. The plugin also honors Off and Manual policies when supplied by the host; this change does
not add a Hugging Face cookie picker or a browser-only source. Browser identity is verified afresh for each wallet
observation, even when the token identity is cached. Wallets for other or unverified accounts are omitted rather
than presented as a separate account or reconciled across token accounts.
