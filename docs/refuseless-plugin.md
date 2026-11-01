---
summary: "Optional local CodexBar plugin for the Refuseless API credit balance."
read_when:
  - Installing the Refuseless plugin example
  - Checking what the Refuseless balance request reads
---

# Refuseless plugin example

`Examples/Plugins/refuseless.js` is an optional user-installed plugin for the Refuseless API. Install it from **Settings → Plugins → Install…** and enter a Refuseless API key in the secure API key field. CodexBar requires the plugin's normal origin approval before making a request.

Each refresh makes one read-only `GET https://api.refuseless.com/v1/credits` request with bearer authentication. Refuseless documents this endpoint as free to read and account-scoped to the API key. The plugin does not call chat, completion, or other inference endpoints, so checking the balance does not spend inference credits. It does not start a login flow or use browser cookies.

The plugin follows the published [Credits API](https://docs.refuseless.com/api/credits), [Get credit balance reference](https://docs.refuseless.com/api-reference/credits/get-credit-balance.md), [authentication guide](https://docs.refuseless.com/authentication), and [OpenAPI schema](https://docs.refuseless.com/openapi.json). The response must contain `object: "credits"`, `unit: "usd"`, numeric `balance`, `reserved`, and `available`, a numeric or null `key_limit`, and integer Unix-seconds `updated_at`. Amounts may have up to six decimal places.

The details show `available` as the amount a new request can reserve, `balance` including in-flight requests, and `reserved` for those in-flight requests. `key_limit` is remaining key or workspace budget, not a total quota; `null` means no key budget, while zero remains a real `$0.00` value. The plugin uses the API's `available` and `key_limit` values directly. It does not derive a percentage, spend history, allowance total, or reset schedule from the balance response.

The provider's `updated_at` value appears as a UTC timestamp. Missing or malformed documented fields fail closed with a prompt to update the plugin and retry, then contact Refuseless support if the issue persists. HTTP 401 is reported as an API-key problem, 429 as rate limiting, and 5xx as provider unavailability; other unsuccessful status codes include retry and support guidance. Response bodies are not shown in errors.

The committed Swift Testing tests use local fixtures based on the published OpenAPI schema, but their execution remains unverified because the focused runner emitted no test events or counts. A separate native probe passed 54 fixture-based assertions across QuickJS and JavaScriptCore; its transport was also fixture-only. The installed CodexBar CLI 0.82.0 has since completed a live authenticated balance request; the redacted proof is in [PR #4886's Validation section](https://github.com/steipete/CodexBar/pull/4886#validation).
