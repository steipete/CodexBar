---
summary: "Cosmic AI project input/output token usage through the official CLI's dashboard API."
provider_id: cosmic
provider_name: Cosmic AI
provider_source: Explicit Personal Access Token and Project ID for separate project AI input/output counters and allowances.
plugin_scope: Fixed-origin bearer GET to the official CLI's project usage endpoint on both engines; explicit project scope, no generation or guessed resets.
read_when:
  - Configuring Cosmic AI
  - Debugging Cosmic project token usage
---

# Cosmic AI

Cosmic AI is disabled by default. In Settings → Providers → Cosmic AI, enter a **Personal Access Token** and the
**Project ID** to monitor. Create a token in [Cosmic Account Settings → API Tokens](https://app.cosmicjs.com/account/api-tokens).
Alternatively, set `COSMIC_TOKEN` and `COSMIC_PROJECT_ID`. The masked token and Project ID are saved in CodexBar's
local config file (`apiKey` and `workspaceID` in the `cosmic` provider entry). Bucket read/write keys are not supported.

The bundled `cosmic.ts` plugin uses the read-only endpoint underlying the official `cosmic billing usage` command:

```text
GET https://dapi.cosmicjs.com/v3/projects/usage?project_id=<Project ID>
Authorization: Bearer <Personal Access Token>
Origin: https://app.cosmicjs.com
```

The **Input tokens** and **Output tokens** meters pair `usage.ai.input_tokens` / `output_tokens` with
`plan_info.ai_tokens.max_input` / `max_output`. The observed allowances can be decimal strings with `k` or `M`
suffixes, as in the official CLI. Detail rows show usage, allowance, remaining tokens, and any amount above the
allowance separately for each dimension. Usage covers only the configured project; it is not summed across projects
or workspaces. The token can authorize other operations, but CodexBar only performs this GET.

Missing counters remain unknown. A zero, absent, or nonnumeric allowance has no percentage meter; any reported
counters remain visible. An explicit unlimited allowance stays labeled unlimited, and other unrecognized strings
leave the allowance unknown. Invalid numeric counters fail parsing without including the response body in the error.
No marketing-page Free allowance is hardcoded.

The official usage response does not define reset timestamps, billing dates, purchased token-pack balances, or
monetary overage charges. CodexBar leaves them absent and does not combine one-time token packs with a recurring
allowance. It does not execute AI generation, use generation-response telemetry as account quota, read CLI credentials,
import browser cookies, or start a login flow. The dashboard API is used by Cosmic's public CLI but can change.

```sh
codexbar usage --provider cosmic --source api --json
```

Sources checked October 8, 2026:
- [Cosmic CLI documentation](https://www.cosmicjs.com/docs/cli) — Personal Access Tokens and project billing usage.
- [Official CLI billing API](https://github.com/cosmicjs/cli/blob/main/src/api/dashboard/billing.ts) — GET route and `ProjectUsageResponse` schema.
- [Official CLI usage display](https://github.com/cosmicjs/cli/blob/main/src/commands/billing.ts) — independent input/output mapping and allowance suffixes.
- [Official CLI HTTP client](https://github.com/cosmicjs/cli/blob/main/src/api/client.ts), [authentication](https://github.com/cosmicjs/cli/blob/main/src/auth/manager.ts), and [configuration](https://github.com/cosmicjs/cli/blob/main/src/config/store.ts) — origin header, bearer token, and API origin.

Tests use synthetic fixtures derived from that public schema on both JavaScript engines. No live account was used
to verify this integration.
