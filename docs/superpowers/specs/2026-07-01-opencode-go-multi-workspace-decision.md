---
summary: "Decision brief for showing multiple OpenCode Go workspaces from one account."
read_when:
  - Designing OpenCode Go multi-workspace usage
  - Changing OpenCode Go workspace discovery or menu rendering
---

# OpenCode Go multi-workspace usage

**Status:** needs maintainer decision
**Issue:** [#1626](https://github.com/steipete/CodexBar/issues/1626)
**Date:** 2026-07-01

## Problem

One OpenCode account can have several workspaces, each with its own Go subscription. CodexBar discovers workspace
identifiers but selects only the first one, stores one optional workspace override, and projects one scalar usage
snapshot. Users must replace the override and refresh to inspect another workspace.

This is not multi-account support: the browser session is shared. Workspace identity scopes the usage request and the
rendered result.

## Verified constraints

- OpenCode Go subscriptions belong to workspaces. OpenCode's public Go documentation says one member per workspace may
  subscribe.
- Current discovery parsing yields workspace identifiers only. A stable, authenticated response field or endpoint for
  display names still needs redacted live proof before names become a persisted contract.
- The current snapshot, refresh state, settings field, CLI projection, and menu card are single-workspace.
- Open PR [#1788](https://github.com/steipete/CodexBar/pull/1788) changes the same parser and snapshot files. Any
  implementation must start after that PR is resolved and rebase onto its final shape.
- Shared token-account rows are the wrong identity model: separate workspace results reuse one credential.

## Options

### A. Automatic fan-out with stacked cards — recommended

Discover all workspaces on refresh, fetch them with the same authenticated session, and render one stacked card per
workspace. Keep the existing workspace override as an explicit single-workspace filter for troubleshooting and large
accounts.

Benefits: matches the request, requires no duplicated cookies, and follows the existing Kilo scoped-snapshot and stacked
card patterns. Costs: refresh fan-out, partial-failure state, ordering, and a new workspace-scoped snapshot model.

### B. Settings-selected workspaces

Add a discovery/selection list in Preferences and fetch only checked workspaces.

Benefits: bounded network work and explicit control. Costs: cached workspace metadata, stale-selection handling, more
setup, and a surprising default for a user expecting all subscriptions to appear.

### C. Workspace submenu

Show one provider card and put workspace results in a submenu.

Benefits: compact menu. Costs: hides usage, adds provider-specific navigation, and does not reuse the shared stacked-card
presentation.

## Recommended contract

Choose option A with these boundaries:

1. Add `OpenCodeGoWorkspace` with an identifier and optional display name. Never use a name as a request key.
2. Discover once per refresh, preserve server order or sort by stable display label, and deduplicate identifiers.
3. Fetch workspaces with a bounded task group. Isolate per-workspace failures; one failure must not erase successful
   sibling snapshots.
4. Store workspace-scoped snapshots separately from token accounts. Project the workspace name through provider identity
   for stacked-card and CLI labels.
5. Preserve the existing override as a single-workspace filter. An invalid override reports that workspace's error and
   does not silently select the first discovered workspace.
6. If the live contract exposes no stable display name, show a redacted identifier suffix and defer name persistence.
7. Keep workspace data inside the OpenCode Go provider. Do not reuse identity or plan fields from another provider.

## Proof required before implementation

- Redacted authenticated discovery response proving stable workspace identifier and name fields, or proving names are
  unavailable.
- Redacted usage responses from two workspaces under one session.
- Packaged-app screenshot showing two stacked cards with no account or workspace secrets.
- Failure proof showing one workspace can fail while another remains visible.

## Acceptance tests

- Discovery deduplicates two or more workspace identifiers and handles missing names.
- Shared credentials produce one request per workspace without persisting duplicate cookies.
- Results stay associated with their workspace when responses complete out of order.
- Partial failures preserve successful sibling cards.
- Manual override fetches only the requested workspace.
- CLI JSON and menu models label every workspace deterministically.
- `make check` and `make test` pass on the exact implementation head.

## Decision requested

Approve automatic all-workspace fan-out with stacked cards and a single-workspace override, or choose settings-based
selection. Do not implement workspace names until the authenticated response contract is proven.
