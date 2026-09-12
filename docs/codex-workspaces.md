# Codex Workspaces local index

Codex Workspaces attributes the existing local Codex cost scan to projects,
sessions, models, and days. This foundation is local-only library behavior; it
does not add a remote API, provider authentication flow, billing interface, or
public CLI JSON contract.

## Internal navigation scaffold

Debug builds can expose a Codex-only **Workspaces** menu action with
`CODEXBAR_ENABLE_WORKSPACES_MENU=1`. It opens one reusable native window showing
**No data yet**; this preparatory navigation slice does not load the index,
start scans, read account data, or persist window geometry. Release builds
always disable this gate, even if the environment variable is present. A
data-backed inspector and an explicit user opt-in remain separate follow-ups.

## Data flow

`CostUsageScanner` remains authoritative for JSONL parsing, cumulative-token
deltas, fork and subagent accounting, pricing, and incremental cursors. The
Workspaces index combines that scan cache with the read-only Codex thread
catalog:

1. Scan local rollout JSONL into the Codex v11 cost cache.
2. Read catalog metadata without modifying the Codex catalog.
3. Canonicalize workspace attribution and scope it to the selected Codex home.
4. Publish the complete source state and derived snapshot in one SQLite
   transaction.
5. Expose project, session, model, daily, source-status, progress, and CSV
   library models to presentation consumers.

The supported internal presentation boundary is:

- `CostUsageFetcher.loadCachedCodexLocalProjectUsageSnapshot`
- `CostUsageFetcher.loadCodexLocalProjectUsageSnapshot`
- `CostUsageFetcher.clearCachedCodexLocalProjectUsageSnapshot`
- `CodexLocalProjectUsageSnapshot`
- `CodexLocalProjectUsageIndexProgress`

## Persistence contracts

The Codex cost cache is:

```text
~/Library/Caches/CodexBar/cost-usage/codex-v11.json
```

The Workspaces sidecar is:

```text
~/Library/Caches/CodexBar/local-usage/codex-workspaces-v1.sqlite
```

The sidecar currently uses SQLite schema version 5 and snapshot payload format
3. This is the first released Workspaces schema. A database with any other
`PRAGMA user_version` is rejected as incompatible and is never modified.

### v10 to v11

`codex-v10.json` is not migrated in place and is not accepted as a v11
incremental cursor. Parser and attribution semantics changed, so the first scan
after upgrading performs a one-time rebuild and writes a separate v11 artifact.
The v10 file remains untouched and recoverable. The v11 file is replaced
atomically only after a successful scan; later v11 refreshes can use the normal
incremental cursor.

### Sidecar rollback

Publication is transactional: a failed synchronization or snapshot write rolls
back and leaves the previous complete snapshot available.

## Catalog completeness and last-good data

Catalog access distinguishes complete, missing, locked, corrupt, and
incompatible states. A complete read replaces catalog metadata for that Codex
home scope. A later same-scope incomplete read reports partial or stale source
status while retaining the last-good catalog attribution and usage snapshot.
Sparse rollout updates do not erase retained titles, workspace paths, or other
catalog metadata.

Scope identifiers and invalidation fingerprints are hashes; raw Codex-home
paths are not persisted as scope identifiers. Changed and deleted rollout files,
parser or pricing changes, history-window changes, and catalog changes
invalidate only the affected cached state.

## Cost and display semantics

Known model cost and unknown-cost coverage are represented separately. Unknown
pricing never becomes a synthetic zero-cost claim. Models analytics, parity
checks, performance telemetry, and CSV serialization operate on the same
persisted snapshot.

Display-only projections are transient:

- Hiding estimated cost does not rewrite the sidecar.
- Including or excluding cached input does not rescan or rewrite the sidecar.
- Hiding personal information removes persisted workspace paths, working
  directories, workspace names, and session titles from snapshots before they
  reach presentation code; it does not rewrite the local sidecar.
- Rankings, totals, charts, and breakdowns must use the same projection.

## Privacy boundary

The scanner, catalog reader, cache, sidecar, analytics, and CSV serializer run
locally. They do not upload rollout contents or catalog records. The stored
index can contain local workspace paths, session metadata, token totals, and
derived cost estimates, so runtime evidence must be sanitized before
publication. Remove paths, titles, session IDs, identities, tokens, keys,
network addresses, and database row contents from shared logs and screenshots.
