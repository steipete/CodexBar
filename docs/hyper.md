---
summary: "Charm Hyper provider setup and Hypercredit balance display."
---

# Charm Hyper provider

CodexBar reads the remaining Charm Hypercredit balance through Charm Hyper's maintained credits endpoint.

## Authentication

In **Auto** mode, CodexBar prefers a signed-in `hyper.charm.land` browser session and falls back to an API key. Automatic session import is Chrome-only; choose **Manual** to paste a Cookie header or **Off** to use only an API key.

For API-key access, create a Charm Hyper API key and add it under **Settings > Providers > Charm Hyper > API key**, or set `HYPER_API_KEY` in the environment used to launch CodexBar. Token accounts are also supported.

Both strategies request `GET https://hyper.charm.land/v1/credits`. Session cookies are sent only to `hyper.charm.land`; API keys are sent only as Bearer tokens to the same host.

## Display

CodexBar displays the returned `balance` in native HC units. The credits response does not establish a plan limit or reset timestamp, so CodexBar does not infer a usage percentage, quota, or reset countdown.

If neither a usable browser session nor an API key is available, CodexBar reports setup guidance instead of showing an empty balance.
