---
summary: "Hugging Face authentication and Inference Providers credit tracking."
read_when:
  - Configuring Hugging Face in CodexBar
  - Debugging Hugging Face token or billing permission errors
  - Adding or tweaking Hugging Face usage parsing
---

# Hugging Face

CodexBar reads monthly Inference Providers credit usage from Hugging Face's billing API and shows spend versus the
included monthly credits as the primary gauge. Accounts with ZeroGPU access also get a secondary ZeroGPU quota window.
Identity (username and PRO/Free plan) comes from `whoami-v2`, cached for hours because Hugging Face rate-limits that
endpoint far more strictly than the rest of the Hub API.

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

- Inference Providers spend versus included monthly credits, with the billing period reset date.
- The user-configured spending limit, when one is set (and it becomes the gauge when the plan includes no credits).
- ZeroGPU GPU-time used/remaining and its reset, when the account has ZeroGPU quota.
- Username and plan (PRO/Free).

## Endpoint contract

The billing endpoint (`/api/settings/billing/usage-v2`) is listed in Hugging Face's OpenAPI spec, but its response
shape is not documented. CodexBar parses it defensively and reports a clear "response format changed" error if the
shape drifts instead of showing partial data. ZeroGPU quota and `whoami-v2` are fully documented endpoints and are
fetched best-effort — their failures never take down the credits gauge.
