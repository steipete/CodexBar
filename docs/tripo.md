---
summary: "Tripo API credit balance and reserved credits."
provider_id: tripo
provider_name: Tripo
provider_source: API key for available and reserved account credits from the official account balance endpoint.
plugin_scope: Fixed-origin bearer GET for available and frozen credits, without inferred quotas or dollar conversions, on both engines.
read_when:
  - Configuring Tripo credits
  - Debugging Tripo account balance responses
---

# Tripo

[Tripo](https://www.tripo3d.ai) generates 3D assets. Enable Tripo in Settings → Providers and save an API key from
[API keys](https://developers.tripo3d.ai/en/keys), or set `TRIPO_API_KEY` for the CLI. The provider is disabled by
default. The key uses CodexBar's existing local provider configuration.

The bundled plugin sends one read-only bearer-authenticated request per refresh:

```text
GET https://openapi.tripo3d.ai/v3/account/balance
```

The [official account contract](https://developers.tripo3d.ai/en/docs/account) requires `code: 0` and numeric
`data.balance` and `data.frozen`. **Balance** is already the available credit amount; **Reserved** is the separate
amount frozen for tasks in progress. CodexBar does not subtract reservations from the balance a second time.
Both fields remain credits even when the console displays currency equivalents, as documented in
[billing](https://developers.tripo3d.ai/en/docs/billing). CodexBar does not convert them to money, infer a total
allowance or reset date, or submit generation tasks.

Missing, malformed, negative, or nonfinite amounts fail instead of appearing as a zero balance. HTTP failures
are classified without displaying the response body. Only `openapi.tripo3d.ai` is authorized for API requests.

This integration was checked against the public contract and synthetic fixtures on both plugin engines;
it has not been verified against a live Tripo account.

The monochrome icon uses the two symbol paths from Tripo's
[official logo](https://developers.tripo3d.ai/assets/icons/logo-light.svg); the original yellow is `#F8CF00`.
