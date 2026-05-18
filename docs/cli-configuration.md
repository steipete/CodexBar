---
summary: "CodexBar CLI configuration commands for provider toggles, API keys, and isolated config files."
read_when:
  - Using codexbar config from scripts or CI
  - Enabling or disabling providers without opening Settings
  - Storing provider API keys from the command line
---

# CLI configuration

`codexbar config` edits the same `~/.codexbar/config.json` file used by the app's Settings → Providers pane.
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
printf '%s' "$Z_AI_API_KEY" | codexbar config set-api-key --provider zai --stdin
```

Only providers that consume config-backed API keys accept this command. Admin API providers may require a key with
organization/usage permissions, not a normal inference key. Browser/OAuth providers such as Grok use their own provider
sessions instead of an xAI API key for CodexBar's billing view, so enable them with
`codexbar config enable --provider grok`.

## Isolated config files

For tests, demos, and CI, point CodexBar at a temporary config file:

```bash
export CODEXBAR_CONFIG=/tmp/codexbar-config.json
codexbar config enable --provider grok
codexbar config providers --json --pretty
```

The override applies to both reads and writes for the current process environment.

## Validation

After hand-editing config:

```bash
codexbar config validate
codexbar config dump --pretty
```

`dump` prints normalized config, including providers omitted from a hand-written file.
