# Charm Hyper usage

CodexBar can show the remaining Hypercredit balance for [Charm Hyper](https://hyper.charm.land).

## Setup

1. Create an API key in the Charm Hyper dashboard.
2. Set `HYPER_API_KEY` in the environment used to launch CodexBar, or add the key under
   **Settings → Providers → Charm Hyper → API tokens**.
3. Enable **Charm Hyper** in the provider list.

CodexBar requests `GET https://api.hyper.charm.land/v1/credits` and displays the returned balance.
The API-key endpoint does not currently expose a plan limit or refresh timestamp, so CodexBar does
not infer a usage percentage or reset countdown.

## Security

The key is sent only as a Bearer token to `api.hyper.charm.land`. CodexBar does not send dashboard
cookies when fetching the API-key balance.
