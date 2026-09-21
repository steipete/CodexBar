---
summary: "GitKraken AI: direct usage API, gk CLI fallback, authentication, and source-specific limits."
read_when:
  - Setting up GitKraken AI usage
  - Debugging GitKraken API or CLI parsing
---

# GitKraken AI

GitKraken is an opt-in provider with **Auto**, **API**, and **CLI** usage sources.
It reads usage only: it never sends an AI prompt, changes your plan, writes GitKraken's settings,
or signs the CLI in during a refresh. Enable it in Settings → Providers → GitKraken AI.

## Source selection

- **Auto** tries the API when a GitKraken access token is configured, then `gk ai tokens`.
  With no API token, it skips directly to CLI. Explicit API and CLI selections never fall back.
- Cancellation and HTTP 429 do not trigger a second request through CLI.
- Setting an API organization ID pins that scope and disables Auto's CLI fallback. The CLI might
  be signed in to a different organization; CodexBar does not switch its organization or borrow
  its credentials. Select CLI explicitly to use its own account and scope instead.

When using unpinned Auto, keep the API token and CLI signed in to the same GitKraken account.
The successful source is labeled `api` or `cli`. A failed API response and a successful CLI response
are never merged; organization details unavailable from CLI are not carried over from API.

## API authentication

API mode uses a **GitKraken session access token**, not an OpenAI/Anthropic API key and not
GitKraken Desktop's “Use your own API Key” setting. This integration does not register an OAuth
client or implement a browser sign-in flow, and it does not use GitLens's OAuth client ID.

For a manual token, sign in to [GitKraken's account usage page](https://gitkraken.dev/account#ai-usage).
In your browser's developer tools, inspect the successful request to
`https://api.gitkraken.dev/v1/ai-tasks/usage`. Copy **only the token value** after `Bearer ` in its
`Authorization` request header into CodexBar's **GitKraken access token** field. For an organization,
copy the matching `gk-org-id` request header into **API organization ID**. Keep this credential private;
do not paste it into issues, logs, or screenshots. Replace it when the server rejects it or it expires.

The masked field uses CodexBar's existing local config storage, **not Keychain**. As with other
manual-token providers, the underlying config contains the credential in plaintext. An environment
variable is an alternative for CLI invocations; shell exports do not normally reach Finder-launched apps.

| Setting | Config field | Environment variable |
| --- | --- | --- |
| Access token | `apiKey` | `GITKRAKEN_API_TOKEN` |
| API organization ID | `workspaceID` | `GITKRAKEN_ORG_ID` |
| Usage source | `source` (`auto`, `api`, `cli`) | — |

`workspaceID` is the existing generic scope field; for this provider it means the GitKraken organization ID.
Configured values take precedence over their corresponding environment variables. Example provider
entry to **merge into**, not replace, your existing config's `providers` array:

```json
{
  "id": "gitkraken",
  "enabled": true,
  "source": "auto",
  "apiKey": "YOUR_GITKRAKEN_ACCESS_TOKEN",
  "workspaceID": "YOUR_OPTIONAL_GITKRAKEN_ORGANIZATION_ID"
}
```

Omit `workspaceID` entirely for unpinned Auto with CLI fallback. Do not leave the illustrative placeholder
in the configuration. New installs use `~/.config/codexbar/config.json`; existing installs may retain
`~/.codexbar/config.json`. See [CLI configuration](cli-configuration.md) for path overrides.

## CLI authentication

Install [GitKraken CLI](https://github.com/gitkraken/gk-cli) and authenticate it yourself:

```sh
gk auth login
gk ai tokens
```

CodexBar invokes that same read-only command with closed stdin, a 15-second timeout, and a 64 KiB
output limit. It resolves an executable named `gk` from the cached login PATH, process PATH, or common
installation paths. `GITKRAKEN_CLI_PATH=/absolute/path/to/gk` supplies an explicit executable. Shell aliases
are not used: an alias named `gk` may actually point to `gitk`.

The CLI strategy does **not** receive the token or organization configured for the API strategy.
It uses the CLI's own login. It reads stdout only after a successful exit and never interprets failure
messages on stderr as a successful quota response.

## Data and display

API mode requests `GET /v1/ai-tasks/usage` with `Authorization: Bearer …` and, when set, `gk-org-id`.
It uses a cookie-free HTTPS session, a 15-second resource timeout, the shared same-origin redirect guard,
and a 64 KiB accepted JSON size limit. It expects the `data` envelope and rejects non-null `error` values.

- Personal bar: `data.used / data.limit`.
- Shared pool bar: `data.organization.used / data.organization.limit`, when present and valid.
- Detail rows: raw credit counts, your shared usage, and the rest of the organization's usage.
  `sharedUsed` is a slice of the organization total, **not an addition to personal `used`**.
- Weekly reset: the API's timezone-qualified `resetsOn` timestamp. `limit: -1` means unlimited;
  `limit: 0` means no allowance. These have detail rows, not fabricated percentages.

CLI mode supports the published `gk ai tokens` count/reset display, for example:

```text
24,443 of 4,000,000 tokens used (0% consumed)
Reset on 08/17/2025
```

It computes utilization from the counts, not the rounded percentage. Explicit `tokens` and `credits`
labels are retained; an omitted unit is shown as an unspecified allowance, not relabeled as credits.
There is no conversion between legacy tokens and credits. A CLI date-only reset stays a date-only
description: it does not create an invented midnight timestamp or reset countdown. Shared-pool figures
are not synthesized from this display. Multiple or unrecognized summaries fail closed.

This patch does not assume that `gk ai tokens --json` matches the cloud API schema. The CLI text parser
is based on published examples, not a captured authenticated response from your installed version.
Use API mode if your CLI's display differs. Personal/API and CLI allowance figures may not be comparable
across accounting-model changes; test both against your GitKraken UI before relying on the fallback.

No token-cost history, prepaid-balance mapping, status polling, or widget selection is added.

## Testing

Offline, credential-free tests live in `TestsLinux/GitKraken*Tests.swift`; that SwiftPM test target is
included on macOS as well as Linux:

```sh
CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 swift test --filter GitKraken
```

After building, run live reads only when you intend to access your account:

```sh
.build/debug/CodexBarCLI usage --provider gitkraken --source api
.build/debug/CodexBarCLI usage --provider gitkraken --source cli
.build/debug/CodexBarCLI usage --provider gitkraken --source auto
```

The `gk` provider alias is also accepted. Check that API counts match GitKraken, the reset time is correct,
and CLI counts match `gk ai tokens`. With the API token cleared and no API organization pinned, Auto
should use CLI without opening a login window. Explicit API mode without a token should give a setup error.

## Upstream contracts

- [GitLens API usage implementation](https://github.com/gitkraken/vscode-gitlens/blob/9761f154e3b7ad4b51c510c830ef770628fb43c7/src/plus/ai/aiProviderService.ts)
- [GitLens request headers](https://github.com/gitkraken/vscode-gitlens/blob/9761f154e3b7ad4b51c510c830ef770628fb43c7/src/plus/gk/serverConnection.ts)
- [GitKraken's CLI command reference](https://gitkraken.github.io/gk-cli/docs/gk_ai_tokens.html)
- [GitKraken's published CLI display example](https://www.gitkraken.com/blog/save-time-with-our-new-ai-focused-cli-commands)

The provider icon is the GitKraken mark from [Simple Icons](https://github.com/simple-icons/simple-icons/blob/develop/icons/gitkraken.svg).
