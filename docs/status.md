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
- Component groups rotate their disclosure chevron when expanded or collapsed; child rows and the native menu height update immediately.
- Toggle: Settings → General → Refreshing → “Check provider status”.
- `UsageStore` polls status and stores `ProviderStatus` for indicator/description.
- Overlapping requests keep the newest successfully published status for each provider. Older completions cannot replace its status or components, emit recovery hooks, or schedule a redundant retry. A failed newer request still permits an older success to supply status.
- App and CLI share Core's status-feed decoder and transport-injected fetcher. The app requests component summaries and Workspace
  incidents; CLI `--status` retains its lightweight Statuspage request and existing JSON fields.
- Menu shows incident summary + freshness; icon overlays indicator.
- Settings sidebar dots describe provider service health in their hover tooltip and the provider row’s accessibility label.
  Unknown or unfetched status is gray. This state is independent of quota refreshes and local cost scans, so a service
  incident can remain visible while usage refreshes succeed.
- Cached provider tabs retain their own status components and website links, including on the first switch after opening the merged menu; providers without a curated component submenu keep a plain website link.

## Workspace incidents
- Feed: `https://www.google.com/appsstatus/dashboard/incidents.json`.
- Uses the Gemini product ID from provider metadata.
- Chooses the most severe active incident for the provider.

## Links
- If `statusPageURL` is set, status polling uses it and the menu action opens it.
- If only `statusLinkURL` exists, the menu action opens it without polling.

See also: `docs/providers.md`.
