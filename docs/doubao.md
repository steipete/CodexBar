---
summary: "Doubao provider notes: API-key auth and Volcengine Ark request-limit tracking."
read_when:
  - Adding or modifying the Doubao provider
  - Debugging Doubao API-key setup
  - Explaining Doubao usage display
---

# Doubao Provider

Doubao tracks Volcengine Ark request-limit headers by probing the chat-completions endpoint with a configured API key.

## Setup
1. Enable **Doubao** in Settings → Providers.
2. Paste an API key in the provider settings, or set `ARK_API_KEY`, `VOLCENGINE_API_KEY`, or `DOUBAO_API_KEY`.
3. Refresh provider usage.

## Behavior
- Endpoint: `POST https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions`
- Probe models: `doubao-seed-2.0-code`, `doubao-1.5-pro-32k`, `doubao-lite-32k`
- Reads `x-ratelimit-remaining-requests`, `x-ratelimit-limit-requests`, and `x-ratelimit-reset-requests` when returned.
- If the key is valid but rate-limit headers are missing, CodexBar shows the key as active and links to the dashboard for details.
