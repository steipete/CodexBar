---
summary: "OpenDesign subscription windows from the current workspace's browser session."
provider_id: opendesign
provider_name: OpenDesign
provider_source: Browser or manual session cookies for the active workspace's five-hour and weekly subscription allowance.
plugin_scope: Opaque first-party browser session; current-workspace lookup and subscription quota GETs on both engines.
read_when:
  - Configuring OpenDesign subscription usage
  - Debugging OpenDesign workspace quotas or authentication
---

# OpenDesign

OpenDesign tracks the subscription allowance of the active workspace at <https://open-design.ai/cloud/dashboard>.
The bundled JavaScript plugin reads the same workspace and quota endpoints as the website. It does not estimate
subscription usage from local logs or treat plan credits as money.

## Authentication

Enable OpenDesign in Settings → Providers, sign in at <https://open-design.ai/cloud/login> in a supported browser, and refresh CodexBar.
Automatic import uses the shared browser order and access gate: background and settings refreshes never prompt,
and a manual refresh stops after the first validated session.

For manual setup, copy the Cookie request header from the website's quota request to
`amr-api.open-design.ai`, including `__Secure-better-auth.session_token`. Paste it into the provider's Cookie header
field, or use the CLI's `config set-cookie --provider opendesign --stdin` command. Manual headers work on Linux;
automatic browser import is macOS-only. Cookie source Off disables access. Inference API keys cannot authenticate
these billing endpoints, so there is no API-key fallback.

Cookies remain opaque to the script. The host sends only cookies applicable to the declared API URL, including
applicable parent-domain cookies; it never forwards a host-only website cookie to a different host. Automatic sessions
use no persistent cookie cache. Manual headers use the existing CodexBar config storage.

## Data source and display

The provider performs two read-only GETs on `https://amr-api.open-design.ai`:

1. `/api/v1/workspaces/current` supplies `workspaceId`, the display name, and the membership tier.
2. `/api/v1/workspaces/{workspaceId}/billing/coding-plan-usage`, with the same ID in `X-Vela-Workspace-Id`, supplies
   `eligible`, `tier`, and `windows`. The returned workspace ID must match the discovered one.

The five-hour window (`durationSeconds: 18000`) is Session; the seven-day window (`604800`) is Weekly. Array order
does not affect the mapping. Each percentage is `usedCredits / limitCredits`, with a positive reported allowance in
credit units. A measured zero remains zero. The fetch returns reset times only from a valid `resetsAt`; it never
invents a boundary. The app's shared reset cache may retain a still-valid date previously observed for the same
workspace, but a different workspace ID cannot inherit it. Unrecognized durations are not reinterpreted as one of
these windows.

The workspace name and subscription tier remain attached to that response. This first version follows the website's
current workspace; it does not select or aggregate other workspaces. Local quota history and burn-down widgets are
disabled because the active workspace may change between refreshes. Snapshot time records the CodexBar refresh time.

An ineligible subscription or response without a recognized window reports unavailable usage. Invalid amounts,
duplicate windows, mismatched workspaces, and malformed responses fail rather than producing a full or empty quota.
HTTP 401 rejects the session and tries the next candidate; 403 reports denied billing access without substituting a
wallet from another session. Rate limits and service failures retain their own classifications.

```sh
codexbar usage --provider opendesign --source web --json
```

These undocumented endpoints may change. The initial fixtures come from the sanitized request/response contract in
[#4601](https://github.com/steipete/CodexBar/issues/4601); no live account was available for independent verification.
