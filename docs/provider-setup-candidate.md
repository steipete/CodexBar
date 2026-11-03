---
summary: "Candidate provider-owned setup declarations for CLI inventory; schema pending maintainer review."
read_when:
  - Reviewing provider setup metadata for issue 4705
---

# Provider setup declaration candidate

This is a reviewable contract candidate for [#4705](https://github.com/steipete/CodexBar/issues/4705),
not an approved public schema. It follows the [maintainer's provider-ownership direction](https://github.com/steipete/CodexBar/issues/4705#issuecomment-6350213065).
The existing `authentication` object from [#4862](https://github.com/steipete/CodexBar/pull/4862) stays unchanged.

`ProviderDescriptor.setup` adds an independent `setup` object to each `config providers --json` row.
Declarations live with the provider, with an `.unknown` default. The CLI does not infer requirements from
supported credentials or fetch modes. It serializes names and guidance, without calling credential resolvers,
authentication checks, cookie imports, login, or usage fetches. Enablement keeps its existing meaning.

## Reading the contract

- `status` is `declared` or `unknown`. Unknown means missing guidance, not unsupported authentication or no setup needed.
- `routes` are alternatives. All `requiredInputs` within a chosen route are needed together. Each input's
  `configFields` and `environmentVariables` name alternative sources; they do not define precedence.
  Config paths are relative to a provider entry. `tokenAccounts.accounts[].token` means a selected token account.
- `method` describes setup, independently of fetch source modes. `platforms` applies to that route's action;
  routes are not filtered by the machine printing the inventory. `command` is omitted when none is declared.
- Interactive routes obtain credentials during the action, so an empty input array does not mean anonymous access.
- `optionalCapabilities` contain enrichment routes, never additional requirements for the primary result.
- IDs are provider-local. Hints carry permissions, opt-in settings, and other constraints; they are prose, not
  machine-evaluated predicates. No readiness or credential validation is implied.

## Exact candidate examples

These are complete `setup` values, with insignificant JSON key order/whitespace chosen for readability.

Copilot:

```json
{
  "status": "declared",
  "routes": [
    {
      "id": "device-login", "method": "deviceCode", "platforms": ["macOS", "linux"],
      "requiredInputs": [], "command": "codexbar config login --provider copilot",
      "hint": "Authorize GitHub's device code to save a Copilot token account."
    },
    {
      "id": "github-token", "method": "token", "platforms": ["macOS", "linux"],
      "requiredInputs": [{"id": "github-token", "configFields": ["apiKey", "tokenAccounts.accounts[].token"], "environmentVariables": ["COPILOT_API_TOKEN"]}],
      "hint": "Supply a GitHub token accepted by the Copilot usage API."
    }
  ],
  "optionalCapabilities": [{
    "id": "budget-extras",
    "hint": "Optional, best-effort budgets for public github.com only. Enable Budget extras in the macOS app; the browser session must match the token account. Quota usage does not need cookies.",
    "routes": [
      {
        "id": "manual-cookie", "method": "cookieHeader", "platforms": ["macOS"],
        "requiredInputs": [{"id": "github-cookie", "configFields": ["cookieHeader"], "environmentVariables": []}],
        "hint": "In the macOS app, select manual cookie source and supply the matching GitHub Cookie header."
      },
      {
        "id": "browser-session", "method": "browserSession", "platforms": ["macOS"], "requiredInputs": [],
        "hint": "Sign in to GitHub in a supported browser and select automatic cookie import in the macOS app."
      }
    ]
  }]
}
```

OpenAI API:

```json
{
  "status": "declared",
  "routes": [
    {
      "id": "admin-api-key", "method": "apiKey", "platforms": ["macOS", "linux"],
      "requiredInputs": [{"id": "admin-api-key", "configFields": ["apiKey", "tokenAccounts.accounts[].token"], "environmentVariables": ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"]}],
      "hint": "Use an organization Admin API key for organization costs and usage. Project/service-account keys cannot read those endpoints."
    },
    {
      "id": "legacy-api-key", "method": "apiKey", "platforms": ["macOS", "linux"],
      "requiredInputs": [{"id": "legacy-api-key", "configFields": ["apiKey", "tokenAccounts.accounts[].token"], "environmentVariables": ["OPENAI_API_KEY"]}],
      "hint": "A normal API key supports only best-effort legacy balance fallback, not organization usage. Configured keys with project scoping do not use that fallback."
    }
  ],
  "optionalCapabilities": []
}
```

Azure OpenAI:

```json
{
  "status": "declared",
  "routes": [{
    "id": "deployment-api-key", "method": "apiKey", "platforms": ["macOS", "linux"],
    "requiredInputs": [
      {"id": "api-key", "configFields": ["apiKey"], "environmentVariables": ["AZURE_OPENAI_API_KEY"]},
      {"id": "endpoint", "configFields": ["enterpriseHost"], "environmentVariables": ["AZURE_OPENAI_ENDPOINT"]},
      {"id": "deployment", "configFields": ["workspaceID"], "environmentVariables": ["AZURE_OPENAI_DEPLOYMENT_NAME"]}
    ],
    "hint": "Supply a key, HTTPS resource endpoint, and deployment name. API version is optional. A usage refresh sends a potentially billable validation request, not a usage-history query."
  }],
  "optionalCapabilities": []
}
```

All other built-in providers, loaded user plugins, and retained unavailable plugins:

```json
{"status":"unknown","routes":[],"optionalCapabilities":[]}
```

## Coverage and limitations

Sources: [Copilot](copilot.md) and its device flow/budget fetcher; [OpenAI API](openai.md),
`OpenAIAPISettingsReader` and the bundled `openai` plugin; [Azure OpenAI](azure-openai.md) and its settings reader.
Existing runtime precedence, selected-account behavior, platform support, and permission restrictions still apply.
Copilot budget enrichment must be enabled separately in the macOS app and does not apply to enterprise hosts.
The current CLI settings path cannot enable it, including with a manual cookie on Linux. OpenAI project scoping
is optional and may suppress legacy fallback; an Admin key in either listed environment variable must actually have
Admin API access. This describes API Platform access, not ChatGPT/Codex subscription credits; it does not resolve #4844.

This bounded candidate does not exhaust optional settings/capabilities, add plugin manifest setup fields, or
validate declaration completeness. Unknown plugins retain their existing inventory fields and authentication omission.
Additional providers and any executable setup orchestration need separate review. Public field names and semantics
still require maintainer approval.
