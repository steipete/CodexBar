---
summary: "abliteration.ai API key setup and prepaid USD credits."
provider_id: abliteration
provider_name: abliteration.ai
provider_source: API key for prepaid USD credits and cumulative usage.
plugin_scope: Read-only credits through the official API on both engines.
read_when:
  - Configuring abliteration.ai
  - Debugging abliteration.ai credits
---

# abliteration.ai

Enable **abliteration.ai** in **Settings → Providers** and enter your **API key** in the existing secure field.
The key follows CodexBar's standard local config storage policy. The CLI also accepts `ABLITERATION_API_KEY`;
a saved provider key takes precedence.

```sh
codexbar usage --provider abliteration --source api --json
```

Each refresh makes one non-billable `GET https://api.abliteration.ai/v1/credits` request with bearer authentication.
It never sends inference requests, imports browser cookies, or starts a login flow. The verified response contract is:

```json
{"data":{"total_credits":50.0,"total_usage":0.010637}}
```

Both counters are USD. **Balance** is total credits minus cumulative usage, floored at zero to match OpenRouter's
credits display. The **Credits** meter shows used / total dollars, capped at 100% when overspent; the reported spend
remains visible. Zero total credits retain the dollar amounts without inventing a percentage. Missing, negative,
non-numeric, or non-finite counters fail closed. No reset date, monthly allowance, or pace is inferred.

HTTP 401/403 asks you to check the API key in Settings. HTTP 429 uses the shared rate-limit handling.
The provider does not collect cost history or account identity. Both JavaScript engines use the same bundled plugin.

Branding comes from the public [icon](https://abliteration.ai/icon.svg): the three-stroke mark, charcoal `#1B1B1B`,
and warm white `#ECE8E6`. The menu icon omits the square background to preserve template rendering.
