# Manual SSH cost statistics

CodexBar can combine this Mac's ambient native Codex history with one explicitly selected Linux SSH source in the
existing cost card and daily history chart. The feature is off by default. Saving a destination, enabling it,
opening a menu, or refreshing ordinary provider usage does not contact the server.

## Setup and use

1. In Settings → Providers → Codex, find **Manual SSH cost statistics** and enable **Include one SSH server**.
2. Enter an SSH destination and the remote Codex home, normally `~/.codex`. Configure authentication, host-key trust,
   ports and jump hosts in your existing SSH configuration. CodexBar does not install tools or configure SSH trust.
3. If a managed-account cost scope is selected, explicitly choose **Use this Mac’s native history** first. Server
   history is a shared device/log scope; it is not attributed to whichever OAuth account happens to be selected.
4. Click **Refresh server statistics**. The first refresh explains the temporary copying of raw logs and asks for
   consent. During a request, Refresh is disabled and Cancel remains available.
5. Read the source label, cutoff time and any quality notice alongside Today, the selected history window and the
   daily chart. Disable the SSH option to return to the ordinary local presentation.

The Mac needs `/usr/bin/ssh` and `/usr/bin/rsync`. The remote Linux environment needs `rsync`, `find`, `stat` and
`sha256sum` with the GNU options used by the collector. A remote CodexBar CLI is not required. Missing dependencies,
untrusted host keys and interactive authentication requirements produce a local fallback with an error.

Destinations accept one ASCII SSH alias/hostname, optionally prefixed by `user@`; case is preserved. Components
start with a letter, digit or underscore and otherwise contain letters, digits, underscores, dots and hyphens.
Use an SSH alias for IPv6 or additional connection options. Remote homes accept `~/...` or an absolute path with
nonempty ASCII letter/digit/underscore/dot/hyphen components. Spaces, shell syntax, control characters and `.`/`..`
components are rejected. The home field is explicit: an interactive shell's `CODEX_HOME` is not assumed.

## What the numbers mean

The combined view is labeled **Native Codex**. It includes only native JSONL records from local and remote
`sessions` and `archived_sessions` roots. Pi/OMP mirrors are not part of this view. Ordinary local fallback keeps
its original local sources, including enabled mirrors, and is labeled as local rather than as a combined native
result. Account quota bars, managed-account rows and the ordinary persisted Spend Dashboard keep their own scopes.

The amount is an API-equivalent estimate, not an invoice or subscription charge. Both inputs use one frozen Mac
calendar/window and the Mac's available pricing context. The temporary scan database is separate from that pricing
context and from the normal local history database. Unknown pricing remains unknown, and unsupported or incomplete
joint scans fall back to local usage instead of advertising a complete combined amount.

Card and chart consume the same materialized combined snapshot. The server can contribute dates absent locally;
remote-only history can open the chart. Combined project/session drill-downs and temporary-path opening actions are
hidden. Hide Personal Info masks the destination and path inputs and the displayed server label without changing
the statistics.

## Supported overlap

The collector does not add two independently computed totals. Before the common native scan, it verifies complete
ordered JSONL records and constructs canonical inputs for the scanner and its ancestor lookup:

- Identical views of one native session count once.
- If one complete record sequence is a byte-exact prefix of another view of that session, the shared prefix counts
  once and the longer view's suffix remains.
- Different native session identities remain independent, even if their token vectors are equal.
- Basic native parent/child histories require the necessary ancestor records to be available.

Identity is interpreted consistently with the native scanner. This is deliberately a conservative support boundary:
conflicting, cropped, reordered or reformatted views that cannot establish the required relationship are rejected.
Missing session identity, invalid usage/fork timestamps, state or usage records beyond the native reader’s 256 KiB
line limit, unsupported ancestry and unmetered inherited history can also cause local fallback. Longer conversation
records remain supported when they do not carry scanner state or usage. This
does not claim to solve every exported, copied-between-identities or fork-family shape.

The combined report preserves local Priority/Fast evidence from retained usage rows and the local trace database.
Retained pricing follows the exact session and usage-row identity through copy/prefix deduplication; local trace
evidence is scoped to the local session and turn, so an unrelated remote session with the same turn ID stays
independent. Pricing uses the same API Fast rates and frozen Mac pricing configuration as the native report.
Ambiguous trace ownership, unmatched retained rows, aggregate-only evidence without row ownership, and unsupported
inline tier markers still cause local fallback rather than silently becoming Standard. When no remote-specific
tier evidence is available, JSONL-based estimates do not establish parity with the remote machine's independent
trace-aware billing estimate.

If the normal local ledger retains history whose original input is missing or no longer matches, the combined
operation does not replace or trim that ledger. It falls back locally and explains that it cannot reconstruct the
same local coverage. A normal local refresh, where appropriate, remains a separate operation.

## Temporary data and limits

Deduplication requires raw JSONL, which can contain conversations, project paths and other content recorded in a
session. Only regular `.jsonl` files under the two selected roots are eligible. The collector rejects unsupported
paths, symlinks, special files, traversal and case collisions. It does not request `auth.json`, SSH keys, cookies or
the remote trace database.

Collection deliberately reads the selected roots rather than filtering by folder date. An old session file may
contain recent appended work. The current engineering budgets are 10,000 input files, 256 MiB per file on the Mac,
and a 512 MiB received-data threshold. The 300-second collection deadline includes a five-second SSH connection
timeout. A 4 MiB/s transfer limit and a 50 ms filesystem watchdog bound the receiving process's behavior. The total
threshold is a monitored cutoff with scheduling/buffering overshoot, not a filesystem quota; exceeding it fails the
request. A skipped or incomplete file is never silently treated as a complete transfer. On a Linux client whose
shell uses 512-byte `ulimit` units, the conservative per-file guard can reject files above 128 MiB.

The joint preparation also checks its combined local/remote raw-input budget. Selected remote files are moved into
canonical inputs, redundant remote views are removed, and local files are copied, avoiding a second complete remote
raw copy. Temporary SQLite/sidecar storage is additional scan work, governed by the existing scanner limits rather
than represented as part of a hard 512 MiB disk quota.

The remote manifest is checked before and after copying, including stable byte hashes. A changing, replaced,
truncated or vanished source fails the request and asks for another manual attempt; rsync is not presented as a
global filesystem snapshot. Statistics record the collection interval and remain a frozen as-of result.

Request directories are private (`0700`), with private files (`0600`). Raw copies, canonical inputs and temporary
scan files are cleaned before a result is published. Cancellation drains the owned transfer before deletion.
Cleanup failure remains visible and retryable. A foreground transfer guardian retains the activity lock and a
deadline if the App exits unexpectedly. The 300-second deadline starts termination; draining a writer stuck in
uninterruptible kernel I/O may take longer, with the lock retained until writing has stopped. On the next launch,
local cleanup considers only valid marked, owned,
inactive request directories. This is neither immediate cleanup after SIGKILL nor secure erasure of storage media.

## Refresh, failure and restart behavior

Results stay in memory for this App run. After restart, saved settings return to a configured-but-not-refreshed state.
There is no periodic SSH refresh and no persistent remote ledger. During a refresh, a still-valid previous result is
clearly shown with its existing cutoff time. A failed remote read or unsupported merge returns to local presentation;
when no local snapshot is available, it says unavailable rather than inventing a zero.

Changing the destination, home, effective local scope, window, day boundary or relevant configuration revision
invalidates the old result. Menu rendering reads cached revisions; filesystem verification runs off the main actor,
coalescing concurrent lookups. External configuration edits are rechecked on demand after at most five seconds of
cached freshness. While an expired revision is being checked, the view temporarily shows local data; an unchanged
revision restores the retained combined snapshot. Every explicit refresh obtains a fresh revision before SSH and
again before publication. A late result cannot replace newer settings. Ordinary local refreshes are never added
to a previously combined total. SSH revision checks hash the contents of the supported primary/direct Include configuration files, including
explicit config symlink targets, so a same-size edit with a restored timestamp still invalidates a result. They read
at most 1 MiB per file, 8 MiB total and 4,096 direct glob matches; unverifiable inputs prevent a new refresh.
Unsupported direct Include expressions (such as parent traversal, bracket globs or dynamic tokens) also prevent
refresh instead of silently retaining a revision. They do not follow `IdentityFile` references or resolve nested
includes, `Match exec`, DNS or agent state.
Each new manual connection still uses
SSH's actual configuration and host-key checks.

The earlier unmerged `cost --remote` / `--summary-only` prototype is replaced by this native flow. Ordinary CLI cost
commands retain their existing behavior.
