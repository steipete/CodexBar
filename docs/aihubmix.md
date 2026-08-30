---
summary: "AIHubMix provider: Manage Key setup and prepaid USD balance from /api/user/self."
read_when:
  - Configuring AIHubMix usage
  - Debugging AIHubMix Manage Key or balance parsing
---

# AIHubMix Provider

CodexBar reads the prepaid USD balance from AIHubMix's documented account API.

## Authentication

Create a **Manage Key** (System Access Token) in [AIHubMix Settings](https://aihubmix.com/setting), then add it in
CodexBar Settings → Providers → AIHubMix. Inference API keys (`sk-`) are not accepted by this endpoint.

You can also set an environment variable:

```bash
export AIHUBMIX_ACCESS_KEY="..."
```

`AIHUBMIX_TOKEN` is accepted as an alias, matching the AIHubMix CLI.

Or configure it through the CLI:

```bash
printf '%s' "$AIHUBMIX_ACCESS_KEY" | codexbar config set-api-key --provider aihubmix --stdin
```

## Data Source

CodexBar requests:

- `GET https://aihubmix.com/api/user/self`

The request sends `Authorization: <Manage Key>`. CodexBar does not read AIHubMix
browser cookies, dashboard sessions, or inference prompts.

AIHubMix reports remaining and used quota in internal units. USD amounts are `quota / 500000` and
`used_quota / 500000`.

Override the API base URL with `AIHUBMIX_API_URL` (HTTPS URL or bare host). Invalid overrides fail closed.

## Display

The menu card shows the remaining prepaid balance in US dollars. Used spend and lifetime request count appear in the
account details. There is no session or weekly meter.

## CLI Usage

```bash
codexbar --provider aihubmix
codexbar -p aihub
```

## Troubleshooting

- Confirm the key was created under Generate System Access Token, not the inference API-key page.
- A `401` or `403` means AIHubMix rejected the Manage Key.

## Sources

- [Current User Info](https://docs.aihubmix.com/cn/api/CliEndpoints/get-self)
- [Retrieve Account Information via API](https://docs.aihubmix.com/en/api/Cli)
