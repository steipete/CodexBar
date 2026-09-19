---
summary: "Azure OpenAI provider: API key, endpoint, and deployment validation probe."
read_when:
  - Debugging Azure OpenAI provider setup
  - Updating Azure OpenAI endpoint or deployment validation
  - Explaining Azure OpenAI environment variables
---

# Azure OpenAI provider

CodexBar's Azure OpenAI provider validates that a configured deployment is reachable. It does not read Azure spend,
quota history, or token usage history.

## Authentication

Azure OpenAI requires three values:

1. API key
2. Resource endpoint
3. Deployment name

Settings -> Providers -> Azure OpenAI stores those values in the shared CodexBar config. The same values can also be
provided with environment variables:

```bash
export AZURE_OPENAI_API_KEY="..."
export AZURE_OPENAI_ENDPOINT="https://resource.openai.azure.com"
export AZURE_OPENAI_DEPLOYMENT_NAME="chat-prod"
```

You can store the API key through the CLI:

```bash
printf '%s' "$AZURE_OPENAI_API_KEY" | codexbar config set-api-key --provider azure-openai --stdin
```

Example v1 config (`enterpriseHost` is the endpoint; `workspaceID` is the deployment name):

```json
{
  "id": "azureopenai",
  "apiKey": "<AZURE_OPENAI_API_KEY>",
  "enterpriseHost": "https://resource.openai.azure.com",
  "workspaceID": "chat-prod",
  "azureOpenAIAPIVersion": "v1"
}
```

## API version

Settings -> Providers -> Azure OpenAI -> API version has two built-in options:

- **Default**: clears `azureOpenAIAPIVersion`, reads `AZURE_OPENAI_API_VERSION`, and uses `2024-10-21` if unset or blank.
- **OpenAI-compatible v1**: saves `azureOpenAIAPIVersion: "v1"`, overriding the environment variable.

The app and CLI share this config. Custom dated versions can be set in `azureOpenAIAPIVersion` or
`AZURE_OPENAI_API_VERSION`; a nonblank config value takes precedence. A custom configured value appears in the picker.

## Data source

CodexBar sends a JSON POST request with the `api-key` header and one `ping` message:

| API version | Path relative to the resource endpoint | Request parameters |
| --- | --- | --- |
| `v1` | `/openai/v1/chat/completions` | `model: <deployment>`, `max_completion_tokens: 64` |
| Dated version | `/openai/deployments/<deployment>/chat/completions?api-version=<version>` | `max_tokens: 1` |

The v1 completion budget includes reasoning tokens. The response's `model` field supplies the displayed model name.

## Endpoint handling

`AZURE_OPENAI_ENDPOINT` and the configured endpoint field must be HTTPS URLs, or bare hosts that can be normalized to
HTTPS. CodexBar rejects explicit `http://` endpoints, user info, and encoded host-delimiter tricks before attaching the
`api-key` header.

Endpoint paths are preserved. CodexBar avoids duplicating a trailing `/openai` for dated API versions or a trailing
`/openai/v1` for the v1 API when building the validation URL.

Each refresh with complete, valid configuration sends this real, potentially billable inference request. The 64-token
v1 budget is a maximum, not automatic consumption; the deployment can consume fewer input and output tokens.

## Display

- Settings shows the provider's static `api` label before a fetch. After a successful fetch, Settings' Source row and
  the CLI report `deployment`.
- The menu shows the Azure OpenAI resource host as organization context.
- The primary detail line shows `Deployment: <name>` and includes `Model: <model>` when the validation response returns
  one.
- The menu bar usage meter does not show spend, quota, or reset history because the provider only performs deployment
  validation.

## CLI usage

```bash
codexbar usage --provider azure-openai
codexbar usage --provider azureopenai
codexbar usage --provider aoai
```

## Key files

- `Sources/CodexBarCore/Providers/AzureOpenAI/AzureOpenAIProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/AzureOpenAI/AzureOpenAISettingsReader.swift`
- `Sources/CodexBarCore/Providers/AzureOpenAI/AzureOpenAIUsageFetcher.swift`
- `Sources/CodexBar/Providers/AzureOpenAI/AzureOpenAIProviderImplementation.swift`
- `Tests/CodexBarTests/AzureOpenAIUsageFetcherTests.swift`
