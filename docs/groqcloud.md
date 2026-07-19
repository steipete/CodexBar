---
summary: "GroqCloud provider setup and Prometheus metrics usage source."
read_when:
  - Configuring GroqCloud usage tracking
  - Debugging GroqCloud request or token-rate display
---

# GroqCloud

CodexBar's GroqCloud provider is separate from the xAI Grok provider. It uses a GroqCloud API key and the Enterprise
Prometheus metrics API.

## Setup

Store the key in the shared app/CLI config:

```bash
printf '%s' "$GROQ_API_KEY" | codexbar config set-api-key --provider groq --stdin
```

Or set `GROQ_API_KEY` in the process environment. `GROQ_API_URL` can override the default `https://api.groq.com/v1`
base URL for private gateways.

## Menu display

- Primary: requests per minute.
- Secondary: tokens per minute.
- Tertiary: prompt cache hits per minute when the metric exists.
- Dashboard link: GroqCloud metrics dashboard.

If the key lacks Prometheus metrics access, CodexBar shows the API error instead of guessing from unrelated endpoints.
