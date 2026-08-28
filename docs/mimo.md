---
summary: "Xiaomi MiMo provider notes: cookie auth, balance endpoint, and setup."
read_when:
  - Adding or modifying the Xiaomi MiMo provider
  - Debugging MiMo cookie import or balance fetching
  - Explaining MiMo setup and limitations to users
---

# Xiaomi MiMo Provider

The Xiaomi MiMo provider tracks your current balance from the Xiaomi MiMo console.

## Features

- **Balance display**: Shows total balance plus paid and granted components when MiMo returns them.
- **Token plan usage**: Shows current token-plan credits while retaining balance as a second metric.
- **Cookie-based auth**: Uses browser cookies or a pasted `Cookie:` header.
- **Near-real-time updates**: Balance usually reflects within a few minutes.

## Setup

1. Open **Settings → Providers**
2. Enable **Xiaomi MiMo**
3. Leave **Cookie source** on **Auto** (recommended)

CodexBar imports cookies from these browsers in order: **Safari**, **Chrome** / **Chrome Beta** / **Chrome Canary**, **Firefox**, and **Microsoft Edge**. Switch to **Manual** and paste a `Cookie:` header if your active MiMo session lives in Arc, Brave, or another browser profile CodexBar does not auto-detect.

Safari cookie import may require granting CodexBar Full Disk Access in **System Settings → Privacy & Security**.

### Manual cookie import (optional)

1. Open `https://platform.xiaomimimo.com/#/console/balance`
2. Copy a `Cookie:` header from your browser’s Network tab
3. Paste it into **Xiaomi MiMo → Cookie source → Manual**

## How it works

- Fetches balance and token-plan detail/usage endpoints under `https://platform.xiaomimimo.com/api/v1`
- Requires the `api-platform_serviceToken` and `userId` cookies
- Accepts optional MiMo cookies like `api-platform_ph` and `api-platform_slh` when present
- Supports `MIMO_API_URL` to override the base API URL for testing. Override values must be explicit HTTPS URLs or
  bare hosts/paths that CodexBar normalizes to HTTPS. Explicit `http://` values fail closed before MiMo cookies are
  attached to a request, and invalid endpoint overrides do not fall back to local MiMo usage accounting.

## Limitations

- Token cost, status polling, and debug log output are not supported yet
- Widgets do not support Xiaomi MiMo yet
- Auto import covers Safari, Chrome variants, Firefox, and Edge only; other browsers use **Manual** mode

## Troubleshooting

### “No Xiaomi MiMo browser session found”

Log in at `https://platform.xiaomimimo.com/#/console/balance` in Safari, Chrome, Firefox, or Edge, then refresh CodexBar. If your session lives in another browser, switch the MiMo provider to **Cookie source → Manual** and paste the `Cookie:` header instead.

### “Xiaomi MiMo requires the api-platform_serviceToken and userId cookies”

The pasted header or imported browser session is missing required cookies. Re-copy the request from the balance page after logging in again.

### “Xiaomi MiMo browser session expired”

Your MiMo login is stale. Sign out and back in on the MiMo site, then refresh CodexBar.

## Local fallback (opt-in)

When the platform.xiaomimimo.com cookie path is unavailable — Chrome session cookies expire on Chrome relaunch, Chrome Safe Storage keychain access blocked, no SSO login from this machine, etc. — and you drive MiMo inference through a local wrapper such as `cc-mimo` (Claude Code CLI with `ANTHROPIC_BASE_URL=https://token-plan-sgp.xiaomimimo.com/anthropic`), CodexBar can surface **local token accounting** from that wrapper’s session jsonl as graceful degradation — the MiMo card shows lifetime/weekly token sums instead of `login required`.

This fallback is **implicit opt-in**: it only activates when `~/.codexbar/mimo-local-usage.json` exists. Users who do not run a local wrapper see no change.

### Setup (optional)

1. Drop `Scripts/mimo-usage.py` (shipped with this repo) into your `PATH`:

   ```bash
   ln -sf "$(pwd)/Scripts/mimo-usage.py" ~/.local/bin/mimo-usage
   chmod +x ~/.local/bin/mimo-usage
   ```

2. Run `mimo-usage --update` once to populate `~/.codexbar/mimo-local-usage.json`. The tracker scans `~/.claude-envs/mimo/.claude/projects/**/*.jsonl` (default path for a `cc-mimo`-style wrapper) and aggregates input, output, cache-read, and cache-creation tokens per time window (today / this week / all time).

3. Trigger updates either on each wrapper invocation (recommended — call `mimo-usage --update` post-exec from your MiMo CLI launcher) or via a `launchd` / `cron` job every 5 minutes.

4. CodexBar picks up the file on its next refresh. The MiMo card displays `Xiaomi MiMo (local)` with a `Local · <today> · <week> · <lifetime> · <sessions>` summary and the cache's actual update time. Local activity is not rendered as a quota percentage. The `Balance updates / Daily billing finalizes` footer is suppressed for `local` source since neither applies. Because CodexBar only reads this cache (it never regenerates it), a summary whose cache has not refreshed within 12 hours gets a `stale <age>` marker (e.g. `stale 34d`) so a frozen tracker is not misread as live usage — re-run `mimo-usage --update`, or add the scheduled job in step 3, to clear it.

### Wrapper integration example

```bash
"$CLAUDE_CLI" "$@"
_exit=$?
mimo-usage --update 2>/dev/null || true
exit $_exit
```

### Limitations

- **Local accounting only** — this is not real platform quota. The Xiaomi platform may rate-limit your account before your local counter reflects it.
- Override the session root with `MIMO_CLAUDE_HOME` and the cache path with `MIMO_LOCAL_USAGE_PATH` when a wrapper uses non-default locations.
- Cache schema (`~/.codexbar/mimo-local-usage.json`) is internal; do not rely on the JSON shape for external tooling.
