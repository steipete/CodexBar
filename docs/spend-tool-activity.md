# Native session tool activity

Usage & Spend can now answer what a native Codex session did, which recorded operations took longer,
and which results need inspection. Each session has a collapsed Tool activity section, an operation
summary, filters for all/review/slow (at least ten seconds), and individually expandable local details.
Commands below one second use milliseconds. A nonzero exit code is distinct from a tool error and does
not classify the user's task as failed.

## Data contract

- The native cost scanner supplies the selected rollout URL and session identity. Other providers and
  OpenCodex sources do not expose this section. No global home discovery occurs in the view.
- Only native `event_msg/item_completed` operations are indexed: command execution, MCP, dynamic tools,
  file changes, web search, image operations, and extensions. Model orchestration calls are not added.
- Explicit thread ownership is required. Identity is `(thread, turn, item)`; later observations update
  the same operation. Foreign copied history is excluded. Unassignable native operations mark coverage
  partial rather than being guessed into the current session.
- Root completion timestamps follow the chart's calendar and selected date; row dates and times use
  the chart's time zone, so operations on different days remain distinguishable. Native seconds/nanoseconds
  are preferred. Valid start/end intervals are labeled separately; they do not enter the longest native
  execution comparison. Missing timing is unavailable, distinct from a recorded zero. No task wall time
  is calculated by summing parallel operations. Extension `durationMs` is not assumed to be measured
  execution time (for example, sleep can record a requested duration).
- An MCP error, explicit failure, declined operation, and unknown outcome remain distinct. Neither a
  missing result nor a search command's nonzero exit code is turned into a failed task.

## Performance and privacy

Indexing is on demand on an actor, with cancellation checkpoints every 64 KiB. A streaming projection
skips arguments, result content, file diffs, and unknown values structurally, even when timing fields
follow multi-megabyte output. Metadata projection is capped at 128 KiB, retained strings at 8 KiB,
nesting at 64, a scan at 256 MiB, and operations at 20,000. Incomplete tails, malformed records, missing
native identities/timestamps, and reached limits produce a partial-coverage notice.

At most four source snapshots and 20,000 operations in total are cached only in memory. Unchanged files
reuse the cache; changed files are rescanned conservatively. This version does not claim an incremental
append index. File identity,
size and modification date are checked before/after reads; stale byte offsets are rejected. There is
no tool activity work in routine billing refreshes and no new persistent database or dependency.

The scanner's optional session-source descriptor changes the generated parser fingerprint but does
not change stored billing rows. Databases from current main (`379b799bb4b91683`), the previous tool
inspection build (`7ce21041b7a36242`), earlier main (`0d8f9504f8e63d0f`), and the stable 0.73.0 release
(`7ff985e81e281a11`) are adopted in place through the existing compatible-predecessor mechanism.
Retained history, saved pricing, previous reports and scan checkpoints must survive.

Each operation retains a short command preview and record position. Input/result bodies are read only
when the user expands that operation, bounded to a 4 MiB record and shortened display text. Larger
records expose a clearly labeled raw record preview. Hide personal info suppresses names/previews and
disables body reads. Existing spend JSON exports do not include rollout paths or tool bodies. No
credentials, provider calls, tracing configuration, or execution of recorded commands is required.

Retained turn/item identities are limited to 256 UTF-8 bytes; oversized identities are excluded and
mark coverage partial. Names and command previews have both character and byte limits. Detail text is
limited to 16,000 characters / 64,000 UTF-8 bytes for inputs and 32,000 characters / 128,000 bytes for
results, whichever is reached first. Large structured results use compact JSON to limit indentation
growth. UTF-8 prefixes end on valid scalar boundaries; shortened detail text is explicitly marked.

Detail presentation is keyed by the operation and source file identity, size and modification date.
An older body's display is suppressed immediately when the key changes, before the next asynchronous
load starts. Superseded reads cannot replace a newer result or error state. Collapsed and privacy-hidden
details release their bodies; cancelled reads do not publish a changed-file warning. Refreshing retains
the expanded list and operation disclosure states while showing a loading indicator, then replaces
their results with the current indexed records.

The section deliberately describes operations in the selected local log, not a guaranteed whole-session
history. Older clients may have no native operation records. Cross-session rankings/trends, full call
trees, retry inference, billing attribution, and other-provider support are outside this first version.
English, Simplified Chinese, Traditional Chinese and Italian copy is supplied; other catalogs explicitly carry
English fallback strings pending translation.

## Validation

Focused production parser/dashboard tests cover native ownership, repeated terminal updates, large
escaped command output, nested MCP image content, namespaces, explicit errors and declines, missing
outcomes, invalid timing, native-vs-interval precedence, malformed and unfinished records, rewritten
files, stale details, cancellation, bounded projection, provider isolation, and calendar filtering.
The production SwiftUI content is rendered in English/Chinese, light/dark, 360/820 point widths and all
three filters. These renders are separate from fresh-bundle interaction checks.

Run with the repository's scrubbed test environment:

```sh
source Scripts/test_environment.sh
swift test --build-system native --jobs 4 -Xswiftc -gnone \
  --filter 'SessionToolActivity|SpendTool|CostUsage(RequestLedgerMigration|Store|CoverageCompatibility|PerformanceGate|Fetcher)|LocalizationLanguageCatalog|ProviderArchitectureGatekeeper'
make check
```

Set `CODEXBAR_TOOL_UI_PROOF_DIR` to an empty output directory when running
`SpendToolActivityTests` to render production SwiftUI with synthetic operations in English/Chinese,
light/dark, narrow/wide layouts and all filters. This does not launch the app or read personal logs.
Historical contributor runtime receipts and illustrations remain in the history of PR #4363.
The upgrade tests retain saved pricing, ledger rows, scan checkpoints, reports and database identity
across compatible predecessor adoption, including when original logs have been removed.
