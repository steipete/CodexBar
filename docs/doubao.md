---
summary: "Doubao provider notes: arkcli plan usage, API-key auth, and Volcengine Ark request limits."
read_when:
  - Adding or modifying the Doubao provider
  - Debugging Doubao API-key setup
  - Explaining Doubao usage display
---

# Doubao Provider

Doubao reads Coding Plan and Agent Plan quota windows from the official `arkcli` CLI. Existing Volcengine AK/SK credentials and Ark API-key request-limit probes remain supported.

## Setup
1. Enable **Doubao** in Settings → Providers.
2. Install `arkcli`, then run `arkcli auth login`.
3. Refresh provider usage. CodexBar resolves `arkcli` through `ARKCLI_PATH`, the login-shell/host `PATH`, and standard install locations.

To keep using API credentials instead, paste an API key or AK/SK pair in provider settings. Environment variables `ARK_API_KEY`, `VOLCENGINE_API_KEY`, and `DOUBAO_API_KEY` remain supported.

## Behavior
- Auto mode honors configured API credentials first so an ambient arkcli SSO session cannot silently switch accounts. Without configured credentials, it uses `arkcli usage plan --format json`.
- CLI mode uses only `arkcli`; API mode uses only configured AK/SK or Ark API-key credentials.
- `arkcli` output provides distinct personal and team Coding Plan and Agent Plan 5-hour, weekly, and monthly windows when those subscriptions are present.
- Ark API-key endpoint: `POST https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions`
- Probe models: `doubao-seed-2.0-code`, `doubao-1.5-pro-32k`, `doubao-lite-32k`
- Reads `x-ratelimit-remaining-requests`, `x-ratelimit-limit-requests`, and `x-ratelimit-reset-requests` when returned.
- If the key is valid but rate-limit headers are missing, CodexBar shows the key as active and links to the dashboard for details.
- Agent Plan bearer keys for `/api/plan/v3/chat/completions` are not part of the arkcli usage path; see issue #1835.
