---
summary: "Qwen Code provider: local session log parsing and daily request usage."
read_when:
  - Debugging Qwen Code usage
  - Updating Qwen Code provider behavior
---

# Qwen Code

## Data source
- Local JSONL logs written by Qwen Code:
  - `~/.qwen/projects/<project-id>/chats/*.jsonl`
- Each JSONL record includes `timestamp`, `type`, and (for assistant records) `usageMetadata`.

## Usage model
- Counts assistant records with `usageMetadata` within the **local-day** window.
- Daily request limit defaults to **2,000** (Qwen OAuth free tier).
- Override in Settings → Providers → Qwen Code ("Daily request limit").
- Optional environment override: `CODEXBAR_QWENCODE_DAILY_REQUEST_LIMIT`.

## Identity
- If `~/.qwen/oauth_creds.json` exists, Qwen OAuth credentials are read and the email is derived from `id_token` when possible.

## Notes
- No public usage/quota API exists yet; when available, add an API strategy and prefer it over local logs.
