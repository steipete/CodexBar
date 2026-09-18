---
summary: "Bifrost provider setup and usage data shape."
read_when:
  - Configuring Bifrost usage tracking
  - Troubleshooting Bifrost virtual-key usage in CodexBar
---

# Bifrost

[Bifrost](https://github.com/maximhq/bifrost) is a self-hosted AI gateway. CodexBar reads a virtual key's own
governance budgets and rate limits through Bifrost's self-service quota endpoint — no admin/master credential is
required or used.

Configure it in Settings -> Providers -> Bifrost, or in `~/.codexbar/config.json`:

```json
{
  "id": "bifrost",
  "enabled": true,
  "apiKey": "<BIFROST_API_KEY>",
  "enterpriseHost": "https://bifrost.example.com"
}
```

Equivalent environment variables:

```bash
export BIFROST_API_KEY=vk-...
export BIFROST_BASE_URL=https://bifrost.example.com
```

Both the virtual key and the base URL are required; Bifrost has no default public host and CodexBar does not guess
one. The base URL must use HTTPS unless it names a loopback or private-network address, or a `.local` mDNS host, and
must not embed credentials because the key is sent to it as a header. Plain HTTP remains available for self-hosted
gateways on loopback, RFC 1918, link-local, and IPv6 unique-local networks. A base URL that does not meet these rules
is rejected, and the provider reports that `BIFROST_BASE_URL` is invalid instead of fetching.

## Data Source

The provider calls:

```
GET {baseURL}/api/governance/virtual-keys/quota
x-bf-vk: <virtual key>
```

This is a self-service endpoint scoped to the calling virtual key — it ships in Bifrost's open-source edition with no
admin middleware, and CodexBar never requests or stores a Bifrost admin/master key.

The response's budgets are ordered by shortest reset cycle: the shortest is the primary window, the next is the
secondary window, and any further budgets appear as additional named windows. Rate limits (token and request) appear
as additional named windows alongside budgets. Per-model spend for the primary budget is shown as a details section
when Bifrost's request logging provides it. Spend remains visible as an API-spend row even when a key has no
configured budget. A disabled key (`is_active: false`) keeps showing its remaining budgets and rate limits with an
inactive-key marker, rather than being treated as an error, unless it has neither budgets nor rate limits.

Bifrost's `override_amount`/`override_mode`/`override_cycles_remaining` fields, and its `d`/`w`/`M`/`Q`/`Y` reset-cycle
shorthand, are resolved client-side to compute the effective limit and next reset date shown in CodexBar; both are
Bifrost-specific and not otherwise exposed by the API.

Per-model rows normalize the upstream `model` ID for display: known AWS Bedrock cross-region geo (`us.`, `eu.`,
`apac.`, `global.`, `us-gov.`) and vendor (`anthropic.`, `amazon.`, `meta.`, …) prefixes, and the trailing Bedrock
revision suffix (`-v1:0`), are stripped, since `per_model_usage[].model` reports that ID verbatim — Bifrost's
`provider/model` request syntax is routing-only and does not shorten it. The `provider` field is shown as a
`provider · model` prefix only when a section actually spans more than one upstream provider; a single-provider
section shows the bare model name, matching every other provider's model rows. A normalization collision (two rows
resolving to the same label) falls back to the raw model ID for the affected rows instead of merging them.

## Security

Treat Bifrost virtual keys as secrets. CodexBar stores configured keys only in provider config or token-account
storage and sends them only to the configured Bifrost base URL.
