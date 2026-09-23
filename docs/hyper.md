---
summary: "Charm Hyper setup, session/API authentication, and Hypercredit balance."
read_when:
  - Configuring Charm Hyper
---

# Charm Hyper

Charm Hyper is an opt-in bundled TypeScript provider. It requests
`GET https://hyper.charm.land/v1/credits` and displays the returned balance in native HC units.

## Authentication

Enable **Settings → Providers → Charm Hyper**. Automatic session access imports Chrome cookies for
`hyper.charm.land`; Manual accepts a Cookie header from that domain, and Off uses only the API key.
Auto prefers the session, falling back to the API key when cookies are missing, the session expires,
or the session request cannot connect. Malformed successful responses fail visibly without fallback.

Add an API key in the provider settings or set `HYPER_API_KEY` in the environment that launches CodexBar.
Saved API keys and manual Cookie headers use the CodexBar config file. Multiple API-key token accounts
are supported; in Auto mode, selecting one uses API mode so an unrelated browser session cannot override that account.
Cookies and bearer keys are sent separately, only to the declared `https://hyper.charm.land` origin.

The CLI supports `codexbar usage --provider hyper --source api`. `--source web` requires a usable session
and never falls back to a key; a configured manual Cookie header works without browser import.
Automatic browser import is macOS-only. On Linux, Auto can fall back to the API key.

## Display and limits

The card and CLI show a **Hypercredits → Balance** detail row. The JSON detail row preserves the numeric
balance in `usageValue` alongside the HC display string. No usage percentage, plan, spend history, limit, or reset countdown is inferred
from this balance-only response. The menu bar can show the balance through the Balance layout token, the Auto % metric,
or the legacy text metric; widgets do not support it.
Missing credentials produce setup guidance instead of a fabricated zero balance.

The request and parsing contracts are covered by synthetic fixtures derived from #2502 on both plugin
engines. Live session authentication and dashboard parity were not verified with a real Hyper account.
