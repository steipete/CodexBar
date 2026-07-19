# API Spec Pointers

Use current official docs for provider API behavior. Prefer these searches/pages before patching fetchers:

- MiniMax: `https://platform.minimax.io/docs/llms.txt`; key types differ between pay-as-you-go API keys and Token Plan/Coding Plan keys.
- Deepgram: `https://developers.deepgram.com/llms.txt`; usage/project APIs require Management permissions and project-scoped keys.
- Groq: `https://console.groq.com/docs/prometheus-metrics`; usage metrics use `https://api.groq.com/v1/metrics/prometheus`.
- LLM Proxy/LiteLLM: `https://docs.litellm.ai/`; CodexBar expects an LLM-API-Key-Proxy compatible `/v1/quota-stats` endpoint plus base URL.

When citing docs in a user-facing answer, browse the current page and include source links.
