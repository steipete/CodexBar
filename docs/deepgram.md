---
summary: "Deepgram provider: API key setup, project discovery, and usage-breakdown metrics."
read_when:
  - Debugging Deepgram API key or project selection
  - Updating Deepgram usage parsing or menu display
  - Explaining Deepgram setup to users
---

# Deepgram Provider

[Deepgram](https://deepgram.com) is a speech AI platform that provides APIs for speech-to-text, text-to-speech, audio intelligence, and related voice features.

## Authentication

Deepgram uses API key authentication. Get your API key from the [Deepgram Console](https://console.deepgram.com).

The API key must have access to the project you want to query. For usage data, the key also needs the `usage:read` scope for that project.

### Environment Variables

Set the `DEEPGRAM_API_KEY` environment variable:

```bash
export DEEPGRAM_API_KEY="dg_..."
```

Optionally set a Deepgram project ID:

```bash
export DEEPGRAM_PROJECT_ID="your-project-uuid"
```

If `DEEPGRAM_PROJECT_ID` is omitted, CodexBar calls Deepgram's project list endpoint and aggregates usage across all projects visible to the API key.

### Settings

You can also configure the API key and optional project ID in CodexBar Settings → Providers → Deepgram.

### CLI config

```bash
printf '%s' "$DEEPGRAM_API_KEY" | codexbar config set-api-key --provider deepgram --stdin
```

## Data Source

The Deepgram provider fetches summarized usage data from the Deepgram Management API.

1. **Projects API** (`/v1/projects`): Lists projects visible to the API key when no project ID is configured.
2. **Usage Breakdown API** (`/v1/projects/{PROJECT_ID}/usage/breakdown`): Returns summarized project usage over a date range. The response includes fields such as `start`, `end`, `resolution`, and `results`.

Each usage result may include:

* `start`
* `end`
* `hours`
* `total_hours`
* `agent_hours`
* `tokens_in`
* `tokens_out`
* `tts_characters`
* `requests`

Deepgram's usage breakdown endpoint supports querying with `start` and `end` date parameters. The response includes summarized usage results for the selected period.

## Display

The Deepgram menu card shows:

* **Usage notes**: Request count, total audio hours, total billable hours, agent hours, token totals, and TTS characters when returned by Deepgram
* **Identity**: Project name, project ID, or aggregated project count

Deepgram does not currently provide a credit balance through this provider. The provider displays usage, not remaining credits.

## CLI Usage

```bash
codexbar --provider deepgram
codexbar -p dg  # alias
```

## Environment Variables

* **DEEPGRAM_API_KEY**: Your Deepgram API key. Required.
* **DEEPGRAM_PROJECT_ID**: Optional Deepgram project UUID. Leave unset to aggregate all visible projects.
* **DEEPGRAM_API_URL**: Override the base API URL. Optional, defaults to https://api.deepgram.com/v1.

## Permissions

The API key must have permission to read usage data for the configured project.

If the key is valid but lacks the correct scope, Deepgram may return an error like:

```text
INSUFFICIENT_PERMISSIONS
Your account does not have the required scope to perform that action for this project.
Check that your account has the 'usage:read' scope for this project.
```

In that case, create or update a Deepgram API key with the `usage:read` scope for the target project.

## Notes

* Deepgram usage data is project-scoped.
* The project ID should be the project UUID, not just the project display name.
* The provider uses `Authorization: Token <API_KEY>` for requests.
* This provider currently reports usage metrics, not credit balance or per-request cost.
* Summarized usage data is not limited to 90 days, while console logs are limited to 90 days.
