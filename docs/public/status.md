---
summary: "Provider status checks, sources, and indicator mapping."
read_when:
  - Changing status sources or status UI
  - Debugging status polling or incident parsing
---

# Status checks

## Sources
- OpenAI + Claude + Cursor + Factory + Copilot: Statuspage.io `api/v2/status.json`.
- Gemini + Antigravity: Google Workspace incidents feed for the Gemini product.

## Behavior
- Toggle: Settings → Advanced → “Check provider status”.
- `UsageStore` polls status and stores `ProviderStatus` for indicator/description.
- Menu shows incident summary + freshness; icon overlays indicator.

## Workspace incidents
- Feed: `https://www.google.com/appsstatus/dashboard/incidents.json`.
- Uses the Gemini product ID from provider metadata.
- Chooses the most severe active incident for the provider.

## Links
- If `statusPageURL` is set, status polling uses it and the menu action opens it.
- If only `statusLinkURL` exists, the menu action opens it without polling.

See also: `docs/providers.md`.
