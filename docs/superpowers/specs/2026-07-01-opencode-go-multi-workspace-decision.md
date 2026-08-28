---
summary: "Decision brief for showing multiple OpenCode Go workspaces from one account."
read_when:
  - Designing OpenCode Go multi-workspace usage
  - Changing OpenCode Go workspace discovery or menu rendering
---

# OpenCode Go multi-workspace usage

**Status:** automatic fan-out accepted; not implemented
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
- Merged PR [#1788](https://github.com/steipete/CodexBar/pull/1788) made the weekly usage window optional. Multi-workspace
  projection must preserve that rolling-only result shape independently for every workspace.
- Shared token-account rows are the wrong identity model: separate workspace results reuse one credential.

## Options

### A. Automatic fan-out with stacked cards — accepted

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

## Accepted contract

Choose option A with these boundaries:

1. Add `OpenCodeGoWorkspace` with an identifier and optional display name. Never use a name as a request key.
2. Discover once per refresh, normalize and deduplicate identifiers, then sort by normalized identifier. Response timing,
   server order, and display-name changes must not reorder cards.
3. Process no more than 20 discovered workspaces per refresh and no more than 4 workspace pipelines concurrently. If
   discovery returns more, show that results are truncated and direct the user to the single-workspace override.
4. Isolate results per workspace. One workspace failure must not erase or relabel successful siblings; if a previous
   snapshot is retained, mark it stale and associate the current error with the same stable identifier.
5. Store workspace-scoped snapshots separately from token accounts. Project a safe workspace label through provider
   identity for stacked-card and CLI output, but keep the identifier as the association key.
6. Preserve the existing override as a single-workspace filter. When set, skip discovery and fetch exactly that normalized
   identifier. Invalid input fails before networking; request failure never falls back to another workspace.
7. Reuse the one in-memory authenticated session for every workspace pipeline. Never copy or persist cookies per
   workspace, and never include raw credentials or workspace identifiers in logs.
8. If the live contract exposes no stable display name, show a short redacted ordinal or identifier suffix and defer name
   persistence. Persisting names requires separate authenticated contract proof.
9. Keep workspace data inside the OpenCode Go provider. Do not reuse identity or plan fields from another provider.

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
- More than 20 discovered workspaces produce 20 deterministic results plus a visible truncation state.
- At most four workspace pipelines run concurrently.
- Manual override fetches only the requested workspace.
- Invalid overrides fail before any network request; valid failed overrides do not fall back.
- CLI JSON and menu models label every workspace deterministically.
- `make check` and `make test` pass on the exact implementation head.

## Decision

CodexBar accepts automatic workspace fan-out with stacked cards and the existing single-workspace override, bounded by the
contract above. This document does not change runtime behavior. Implementation still requires redacted authenticated
multi-workspace proof, focused parser/model tests, packaged UI proof, and separate review. Workspace-name persistence
remains out of scope until the authenticated response contract is proven.
