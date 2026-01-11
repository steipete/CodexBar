---
summary: "Vertex AI provider data sources: gcloud ADC credentials and Cloud Monitoring quota usage."
read_when:
  - Debugging Vertex AI auth or quota fetch
  - Updating Vertex AI usage mapping or login flow
---

# Vertex AI provider

## Data sources + fallback order
1) **OAuth via gcloud ADC** (only path used in `fetch()`):
   - Reads `application_default_credentials.json` from the gcloud config directory.
   - Uses Cloud Monitoring time-series metrics to compute quota usage.

## OAuth credentials
- Authenticate: `gcloud auth application-default login`.
- Project: `gcloud config set project PROJECT_ID`.
- Fallback project env vars: `GOOGLE_CLOUD_PROJECT`, `GCLOUD_PROJECT`, `CLOUDSDK_CORE_PROJECT`.

## API endpoints
- Cloud Monitoring timeSeries:
  - Usage: `serviceruntime.googleapis.com/quota/allocation/usage`
  - Limit: `serviceruntime.googleapis.com/quota/limit`
  - Resource: `consumer_quota` with `service="aiplatform.googleapis.com"`.

## Mapping
- Matches usage + limit series by quota metric + limit name + location.
- Reports the highest usage percent across matched series.
- Displayed as "Quota usage" with period "Current quota".

## Token Cost Tracking

Vertex AI Claude usage is logged to the same local files as direct Anthropic API usage (`~/.claude/projects/`). CodexBar identifies Vertex AI entries using two methods:

### Detection Methods

1. **Model name format** (primary): Vertex AI uses `@` as version separator
   - Vertex AI: `claude-opus-4-5@20251101`
   - Anthropic API: `claude-opus-4-5-20251101`

2. **Metadata fields** (fallback): Entries with provider metadata
   - `metadata.provider: "vertexai"`
   - Keys containing `vertex` or `gcp`

### Requirements

**To see Vertex AI token costs:**
1. Enable the **Vertex AI** provider in Settings → Providers
2. Enable "Show cost summary" in Settings → General
3. Use Claude Code with Vertex AI (your `cv` alias sets `ANTHROPIC_MODEL=claude-opus-4-5@20251101`)

**Note:** The model name must include the `@` format for detection to work. If Claude Code normalizes model names to `-` format when logging, the entries won't be distinguishable from direct Anthropic API usage.

## Troubleshooting
- **No quota data**: Ensure Cloud Monitoring API access in the selected project.
- **No cost data**: Check that `~/.claude/projects/` exists and contains `.jsonl` files from Claude Code usage with Vertex AI metadata.
- **Auth issues**: Re-run `gcloud auth application-default login`.
