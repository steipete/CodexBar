---
summary: "CodexBar CLI configuration commands for provider toggles, API keys, and isolated config files."
read_when:
  - Using codexbar config from scripts or CI
  - Enabling or disabling providers without opening Settings
  - Storing provider API keys from the command line
---

# CLI configuration

`codexbar config` edits the same resolved config file used by the app's Settings → Providers pane.
New installs use `~/.config/codexbar/config.json`; absolute `XDG_CONFIG_HOME` paths and `CODEXBAR_CONFIG` are
supported, and existing `~/.codexbar/config.json` installs keep using the legacy file when no XDG config exists.
The CLI writes the file with `0600` permissions.

## Providers

List persistent provider toggles:

```bash
codexbar config providers
codexbar config providers --json --pretty
```

Enable or disable a provider:

```bash
codexbar config enable --provider grok
codexbar config disable --provider cursor
```

These are persistent app/CLI settings. They are different from `codexbar usage --provider grok`, which is a one-shot
command override and does not edit config.

If every provider is disabled, `codexbar usage` with no `--provider` prints no text output, and
`codexbar usage --json` prints `[]`. Passing `--provider <name>` still fetches that provider for the one command.

## API keys

API keys are stored under the provider entry in config:

```bash
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
```

`set-api-key` enables the provider by default. Add `--no-enable` when you only want to save the key:

```bash
printf '%s' "$OPENROUTER_API_KEY" | codexbar config set-api-key --provider openrouter --stdin --no-enable
```

Useful examples:

```bash
printf '%s' "$OPENAI_ADMIN_KEY" | codexbar config set-api-key --provider openai --stdin
printf '%s' "$ANTHROPIC_ADMIN_KEY" | codexbar config set-api-key --provider claude --stdin
printf '%s' "$DEEPGRAM_API_KEY" | codexbar config set-api-key --provider deepgram --stdin
printf '%s' "$GROQ_API_KEY" | codexbar config set-api-key --provider groq --stdin
printf '%s' "$LLM_PROXY_API_KEY" | codexbar config set-api-key --provider llmproxy --stdin
printf '%s' "$Z_AI_API_KEY" | codexbar config set-api-key --provider zai --stdin
```

For a z.ai team account:

```bash
printf '%s' "$Z_AI_API_KEY" | codexbar config set-api-key --provider zai --stdin \
  --label Team \
  --usage-scope team \
  --organization-id org_... \
  --workspace-id proj_...
```

Use single-line BigModel organization/project IDs; see [z.ai](zai.md).

Only providers that consume config-backed API keys accept this command. Admin API providers may require a key with
organization/usage permissions, not a normal inference key. Browser/OAuth providers such as Grok use their own provider
sessions instead of an xAI API key for CodexBar's billing view, so enable them with
`codexbar config enable --provider grok`.

LLM Proxy also needs a base URL. Use `LLM_PROXY_BASE_URL` for CLI runs, or add `"enterpriseHost"` to the provider entry
in the CodexBar config file.

## Isolated config files

For tests, demos, and CI, point CodexBar at a temporary config file:

```bash
export CODEXBAR_CONFIG=/tmp/codexbar-config.json
codexbar config enable --provider grok
codexbar config providers --json --pretty
```

The override applies to both reads and writes for the current process environment.

## Cost history window

The app setting controls the menu's local cost-history window. For one-off CLI reports, pass `--days`:

```bash
codexbar cost --provider codex --days 90
codexbar cost --provider claude --days 180 --format json --pretty
```

The accepted range is 1...365 days.

## Validation

After hand-editing config:

```bash
codexbar config validate
codexbar config dump --pretty
```

`dump` prints normalized config, including providers omitted from a hand-written file.
