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

The endpoint and deployment are stored as `enterpriseHost` and `workspaceID` in the `azureopenai` provider config:

```json
{
  "id": "azureopenai",
  "apiKey": "<AZURE_OPENAI_API_KEY>",
  "enterpriseHost": "https://resource.openai.azure.com",
  "workspaceID": "chat-prod"
}
```

## Data source

CodexBar sends a minimal chat-completions request to validate the deployment:

```http
POST https://resource.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-10-21
api-key: <api key>
Accept: application/json
Content-Type: application/json
```

For dated API versions, the request body contains one `ping` message and `max_tokens: 1`. A successful response is
parsed only for the returned `model` field so the menu can show deployment detail.

Set `AZURE_OPENAI_API_VERSION` to override the API version. When it is set to `v1`, CodexBar uses Azure's
OpenAI-compatible v1 path, includes the deployment name as the request `model`, and uses
`max_completion_tokens: 1`:

```http
POST https://resource.openai.azure.com/openai/v1/chat/completions
```

## Endpoint handling

`AZURE_OPENAI_ENDPOINT` and the configured endpoint field must be HTTPS URLs, or bare hosts that can be normalized to
HTTPS. CodexBar rejects explicit `http://` endpoints, user info, and encoded host-delimiter tricks before attaching the
`api-key` header.

Endpoint paths are preserved. CodexBar avoids duplicating a trailing `/openai` for dated API versions or a trailing
`/openai/v1` for the v1 API when building the validation URL.

Each refresh with complete, valid configuration sends this real inference request and can consume billable input and
output tokens for the configured deployment.

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
