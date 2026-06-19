---
name: qa-test
description: "CodexBar live QA/e2e testing: run provider usage matrix checks, validate real app config, use Peekaboo for menu proof, use Browser Use/official docs for API spec or logged-in dashboard checks, and handle 1Password credentials safely."
---

# CodexBar Live QA

Use for live provider testing, release smoke tests, menu verification, or debugging “provider works/fails” reports.

## Rules

- Work from the CodexBar repo checkout.
- Use the packaged CLI first: `CodexBar.app/Contents/Helpers/CodexBarCLI`.
- Do not use `CodexBar.app/Contents/MacOS/codexbar`; that is the app binary and may appear to hang as a CLI.
- Never run broad `env`, `set`, or secret regex dumps.
- Use `$one-password` for secrets: all `op` commands inside one persistent tmux session, service account first, no raw secret output.
- Treat browser-cookie/keychain flows as prompt-risky. Prefer CLI/API-token checks and `KeychainNoUIQuery`-safe tests unless the user explicitly requested live UI.
- For current API behavior, browse official provider docs only.

## CLI Matrix

Run the bundled script:

```bash
.agents/skills/qa-test/scripts/live_provider_matrix.sh --enabled
```

Useful modes:

```bash
.agents/skills/qa-test/scripts/live_provider_matrix.sh --provider all
.agents/skills/qa-test/scripts/live_provider_matrix.sh --providers openai,zai,deepseek
.agents/skills/qa-test/scripts/live_provider_matrix.sh --default
```

Interpretation:

- `--enabled` asks `CodexBarCLI config providers` for enabled providers, honoring `CODEXBAR_CONFIG` and default toggles.
- `--default` runs the app-facing default command with no provider override.
- `--provider all` forces every registered provider and is expected to fail for providers without sessions/keys.
- A green app config needs `--enabled` and `--default` clean; `--provider all` is a discovery/triage tool.

## Config QA

Validate config:

```bash
CodexBar.app/Contents/Helpers/CodexBarCLI config validate
stat -f '%Lp %N' "$HOME/.codexbar/config.json"
```

Redact config shape:

```bash
jq '(.providers // []) |= map(.apiKey = (if .apiKey then "<redacted>" else .apiKey end) |
  .secretKey = (if .secretKey then "<redacted>" else .secretKey end) |
  .cookieHeader = (if .cookieHeader then "<redacted>" else .cookieHeader end) |
  (if .id == "stepfun" and has("region") then .region = "<redacted>" else . end) |
  .tokenAccounts = (if .tokenAccounts then (.tokenAccounts | .accounts = (.accounts | map(.token = "<redacted>"))) else .tokenAccounts end))' \
  "$HOME/.codexbar/config.json"
```

Before editing config, make a backup:

```bash
cp "$HOME/.codexbar/config.json" "$HOME/.codexbar/config.pre-qa-$(date +%Y%m%d%H%M%S).json"
chmod 600 "$HOME/.codexbar"/config.pre-qa-*.json
```

## Live Menu QA

Use Peekaboo after CLI checks:

```bash
pkill -x CodexBar || pkill -f 'CodexBar.app/Contents/MacOS/CodexBar' || true
open -n "$PWD/CodexBar.app"
peekaboo menu list-all --json | rg -i 'codexbar'
peekaboo menu click-extra --title codexbar-merged --json
screencapture -x /tmp/codexbar-live-menu.png
```

Crop top-right menu if needed:

```bash
sips --cropToHeightWidth 900 340 --cropOffset 20 2650 /tmp/codexbar-live-menu.png \
  --out /tmp/codexbar-live-menu-crop.png >/dev/null
```

Verify visually with `view_image`. Confirm provider tabs/rows match enabled config and no failing provider dominates the first screen.

## Browser Use

Use `$browser-use` only when a logged-in dashboard, API key page, or provider docs need browser/profile state.

Existing Chrome path:

```bash
mcporter call chrome-devtools.list_pages --args '{}' --output text
mcporter call chrome-devtools.navigate_page --args '{"url":"https://provider.example"}' --output text
mcporter call chrome-devtools.take_snapshot --args '{}' --output text
```

If Browser Use is unavailable, say so and use web search for public official docs; do not substitute isolated Playwright for login/profile-dependent pages.

## Fix Triage

- Missing auth/session: configure key/session if available; otherwise leave provider disabled or report blocked auth.
- Wrong provider API/spec: inspect official docs, then patch fetcher/settings/tests.
- Provider key exists but live API rejects it: keep key stored if useful, disable provider if the menu would show a persistent error.
- User-facing behavior changes need `CHANGELOG.md`.
- Code fixes need focused tests, `make check`, `$autoreview`, and live CLI proof before landing.

## Known CodexBar QA Notes

- OpenAI Admin API key is the useful usage provider key. Project `OPENAI_API_KEY` values can fail legacy credit-balance fallback with 403.
- Deepgram usage requires a key/project with Management API permissions; transcription-only keys can return 403.
- Groq usage uses the Prometheus metrics API, not ordinary inference endpoints.
- MiniMax pay-as-you-go API keys and Token Plan/Coding Plan keys are different; wrong key kind can leave usage unavailable.
