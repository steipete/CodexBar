---
summary: "Charm Hyper provider setup and Hypercredit balance display."
---

# Charm Hyper provider

CodexBar reads the remaining Charm Hypercredit balance through Charm Hyper's API. It does not import browser cookies or reuse OAuth refresh tokens.

1. Create a Charm Hyper API key.
2. Add it under **Settings > Providers > Charm Hyper > API key**, or set `HYPER_API_KEY` in the environment used to launch CodexBar.

CodexBar sends `GET https://hyper.charm.land/v1/credits` with the key as a Bearer token and displays the returned `balance` as HC. No prompts, browser session data, or account identity are sent.

If the key is rejected, create a replacement in the Charm Hyper dashboard and update the saved key.
