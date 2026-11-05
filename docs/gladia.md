---
summary: "Gladia API key setup and month-to-date billed audio from the transcription lists."
provider_id: gladia
provider_name: Gladia
provider_source: API key for month-to-date billed audio summed from pre-recorded and live transcription lists.
plugin_scope: Read-only pre-recorded and live transcription list GETs through the official API on both engines.
read_when:
  - Configuring Gladia
  - Debugging Gladia authentication or billed-audio totals
---

# Gladia

Enable Gladia in **Settings → Providers** and enter an API key. Gladia creates a default key for every account;
find or create one under [API keys](https://app.gladia.io/apikeys) in the Gladia app.

The key is stored in the CodexBar config file. The CLI also accepts `GLADIA_API_KEY`, or a stored key:

```sh
printf '%s' "$GLADIA_API_KEY" | codexbar config set-api-key --provider gladia --stdin
codexbar usage --provider gladia --source api
```

Gladia does not publish a usage, balance, or billing endpoint. Refresh never submits transcription work; the provider
sends the key in the `x-gladia-key` header for read-only requests to `https://api.gladia.io`:

- `GET /v2/pre-recorded?after_date=<month start>`: pre-recorded jobs created this UTC calendar month.
- `GET /v2/live?after_date=<month start>`: live sessions created this UTC calendar month.

List items include `result.metadata.billing_time` (billed seconds: audio duration times distinct channels) but not
transcripts. CodexBar sums `billing_time` for jobs with status `done` and shows billed audio in total, split into
pre-recorded and live, plus the number of completed transcriptions. Queued, processing, and failed jobs are not
counted.

Each list is read in pages of 200, up to 1,000 jobs per list per refresh. When more jobs remain, the affected values
are prefixed with `≥` as a lower bound. Jobs deleted through the API or removed by Gladia's
[data retention](https://docs.gladia.io/chapters/limits-and-specifications/data-retention) no longer appear in the
lists, so the total can be lower than Gladia's invoice. Remaining free hours, plan, and prices are not available
through the API and are not shown.

HTTP 401 means the key is missing, invalid, or revoked. HTTP 429 means Gladia's rate limit was reached.

References: [authentication](https://docs.gladia.io/api-reference/authentication),
[pre-recorded list](https://docs.gladia.io/api-reference/v2/pre-recorded/list),
[live list](https://docs.gladia.io/api-reference/v2/live/list).
