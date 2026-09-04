---
summary: "Development workflow: build/run scripts, logging, and keychain migration notes."
read_when:
  - Starting local development
  - Running build/test scripts
  - Troubleshooting Keychain prompts in dev
---

# CodexBar Development Guide

## Quick Start

### Building and Running

```bash
# Full build, package, and launch (recommended)
./Scripts/compile_and_run.sh

# Also run the sharded test suite before packaging/relaunching
./Scripts/compile_and_run.sh --test

# Just build and package (no tests)
./Scripts/package_app.sh

# Launch existing app (no rebuild)
./Scripts/launch.sh
```

### Development Workflow

1. **Make code changes** in `Sources/CodexBar/`
2. **Run** `./Scripts/compile_and_run.sh --test` to test, rebuild, and launch
3. **Check logs** in Console.app (filter by "codexbar")
4. **Optional file log**: enable Debug → Logging → "Enable file logging" to write
   `~/Library/Logs/CodexBar/CodexBar.log` (verbosity defaults to "Verbose")

## Keychain Prompts (Development)

### First Launch After Fresh Clone
CodexBar does not run a prompt-capable startup Keychain migration. Unified config migration reads retired stores and
clears them only after every source was readable and the new config was persisted. If a source is unreadable, cleanup
and migration completion are deferred to a later launch.

### Subsequent Rebuilds
Ad-hoc development builds can still prompt for browser or provider-owned items because their code-signing identity is
not stable. Use a consistently signed packaged bundle for intentional live credential validation. Routine tests must
use the repository's suppression-safe test harness and never query the real Keychain.

### Why This Happens
- Keychain access control checks the executable's code signature and designated requirement.
- Ad-hoc builds and changed identities may no longer match an existing grant.
- Chromium and provider apps can rotate or recreate their foreign-owned items, replacing prior grants.
- `ThisDeviceOnly` accessibility controls item availability and syncing; it does not repair a code-signature ACL
  mismatch or prevent authorization prompts.

See [Keychain prompts](keychain-prompts.md) for the current user-facing boundary and safe troubleshooting.

## Augment Cookie Refresh

### How It Works
CodexBar checks Augment through the provider fetch pipeline. Auto mode tries the Augment CLI first, then the
browser-cookie web path. The web path reuses cached cookies when possible and imports from supported browsers when
the cache is missing or rejected.

### Refresh Frequency
- Fresh-install default: Adaptive, between 2 and 30 minutes (configurable in Preferences → General). Existing installs
  without a stored cadence retain the legacy 5-minute fallback.
- Minimum: 1 minute
- Cookie import happens automatically when cached cookies need refresh

### Supported Browsers
- Safari, Chrome variants, Edge variants, Brave, Arc variants, Dia, and Firefox.

### Manual Cookie Override
If automatic import fails:
1. Open Preferences → Providers → Augment
2. Change "Cookie source" to "Manual"
3. Paste cookie header from browser DevTools

## Project Structure

Key source, test, and packaging paths (not exhaustive):

```
CodexBar/
├── Sources/CodexBar/          # Main app (SwiftUI + AppKit)
│   ├── CodexbarApp.swift      # App entry point
│   ├── StatusItemController*.swift  # Menu bar icon, menu rendering, and actions
│   ├── UsageStore*.swift      # Usage refresh, caching, widgets, and history
│   ├── SettingsStore*.swift   # User preferences and config persistence
│   ├── Providers/             # App-side provider settings/runtime glue
│   └── Resources/             # Assets and localized strings
├── Sources/CodexBarCore/      # Shared business logic used by app, CLI, and widgets
│   ├── Config/                # Config file model, reader, writer, and validation
│   ├── Providers/             # Provider descriptors, fetchers, parsers, and status probes
│   ├── OpenAIWeb/             # OpenAI dashboard integration helpers
│   ├── WebKit/                # Web session helpers
│   └── Vendored/              # Embedded support code
├── Sources/CodexBarCLI/       # Bundled codexbar command-line tool
├── Sources/CodexBarWidget/    # WidgetKit support
├── WidgetExtension/           # Xcode wrapper for the packaged widget extension
├── Tests/CodexBarTests/       # macOS app/core test suite (XCTest + Swift Testing)
├── TestsLinux/                # Portable and Linux-specific CLI/core tests (target exists on macOS too)
└── Scripts/                   # Build and packaging scripts
```

## Common Tasks

### Add a New Provider
See the canonical [provider authoring guide](provider.md#adding-a-new-provider) for the complete flow.

1. Add the provider identity to `Sources/CodexBarCore/Providers/Providers.swift`.
2. Add the descriptor and the fetcher, parser, settings-reader, or status-probe pieces the provider needs under
   `Sources/CodexBarCore/Providers/YourProvider/`.
3. Register the descriptor from `Sources/CodexBarCore/Providers/ProviderDescriptor.swift`.
4. Add an app-side `ProviderImplementation` under `Sources/CodexBar/Providers/YourProvider/`; implementations can use
   protocol defaults when no custom UI or macOS integration is needed.
5. Add the provider's exhaustive switch case to
   `Sources/CodexBar/Providers/Shared/ProviderImplementationRegistry.swift`.
6. Add icon assets under `Sources/CodexBar/Resources/`.
7. Add focused tests under `Tests/CodexBarTests/` and, for CLI/core behavior that must run on Linux, `TestsLinux/`.

### Debug Cookie Issues
1. Enable Debug → Logging → "Enable file logging" or raise verbosity in the app settings.
2. Reproduce with `./Scripts/compile_and_run.sh`.
3. Check logs in Console.app:
   - Filter: `subsystem:com.steipete.codexbar category:augment`
   - Importer messages include the `[augment-cookie]` prefix

### Debug Menu Bar Placement

Status-item creation checks the item's saved preferred position and its matching legacy key before assigning the
autosave name. Malformed, non-finite, non-positive, and out-of-bounds positions are removed; unrelated items are
untouched. When no display bound is available, finite positive positions are preserved. Isolated placement tests
cover this cleanup without creating status items or changing the user's saved preferences. Passing these tests does
not establish the cause of a position that changes again after launch; that requires runtime placement evidence.

### Run Tests Only
```bash
make test
```

Suite commands retain the default 180-second deadline, including SwiftPM startup and discovery.
The runner reports elapsed time and owned PIDs every 30 seconds even when test output is buffered.
It tracks process birth identities and descendants, including helpers that create separate process
groups or sessions, and drains them before retrying. Separate sessions are allowed: the shell runner
uses them to protect controlling-terminal ownership. The direct command remains unreaped until cleanup
finishes (`waitid` with `WNOWAIT`), preventing reuse of its PID/session. Observed descendant session
leaders can establish ownership of orphaned session members only while a matching live or unreaped
birth identity still anchors that session. Known descendants retain their identities after reparenting;
empty completed sessions retire. If an observed session loses its anchor while unaccounted live members
remain, observation may retain that session as pending only while the direct command is still wait-owned
and running. A nested runner can then finish draining its own child: its unreaped wait handle is not
signal authority for the outer observer, and macOS may hide the exited leader's metadata. Pending members
remain birth-checked even if they change sessions. Uncertainty also follows observed descendants and peers
of a live matching pending session leader, with compatible birth ordering; those identities remain pending
after reparenting or session migration. Unreadable pending metadata fails closed; confirmed exits or replaced
pending births retire without claiming replacements. Pending status grants no ownership or signal authority.
Command exit and every cleanup path require session continuity and fail if uncertainty remains; a detected
replacement session-leader birth still fails immediately, even during observation.
No observation or cleanup deadline is extended. Unavailable metadata for a
known identity also fails cleanup; an unreadable unrelated peer does not abort enumeration.
For the direct child, confirmed metadata absence (ESRCH/ENOENT) can precede a waitable exit on
Darwin. Its unreaped wait handle retains ownership while ordinary polling continues within the
original command deadline. Pending wait status is not completion; permission and I/O errors still
fail. Direct-child cleanup signals require retained wait ownership, even if no birth metadata was
captured. Other PIDs continue to require verified birth identities.

Cleanup sends TERM to verified individual identities, escalates after three seconds, and requires the
owned set to drain within five seconds. Error paths make a final bounded attempt against readable known
identities and reap the direct child, then propagate failure instead of starting another suite/retry.
Initialization failures similarly TERM/KILL/reap the still-owned direct child. Linux treats a zombie
leader with other threads as running. Other PIDs require birth checks before signals, with pidfds used
on Linux when available. macOS descendant signals use `proc_signal_with_audittoken`: a combined native
BSD/unique-identity read must match the tracked birth, then the kernel binds the signal to that PID's
generation while checking the caller's normal signal permissions. A stale generation (including an
exec race) is not signaled; later cleanup attempts can refresh it after matching birth again. Missing
native signal support, permission failures, and I/O errors fail cleanup without a numeric-PID fallback.

This is a bounded metadata polling tracker, not a daemon sandbox. A new session whose leader and attached
ancestry both disappear entirely between observations cannot be discovered reliably. Snapshot enumeration
is not atomic, and unreadable, never-observed descendants cannot be attributed. The initial `swift test list`
discovery/build path is unchanged; the 180-second bound applies to each suite/group command, including its
startup. `Scripts/test_swift_test_sharding.sh` includes synthetic containment tests; they do not launch
Swift, the app, or provider probes. Its native pthread regression runs only on Linux and uses the system C
compiler; macOS runs the corresponding metadata unit tests and reports the native case as skipped.
macOS also runs native audit-token fixtures: deliberately wrong generations leave owned children alive,
matching identities TERM/KILL and reap them, and unrelated sentinels survive. These fixtures use stop
files and self-expiry, with final cleanup restricted to their unreaped direct children.

Process-cleanup fixtures keep ancestry alive until the real ownership refresh observes matching ready
child identities (and the session-tree grandchild), then acknowledges a private fixture gate before drain.
The direct `waitid` fixture uses the same handshake without reaping its root. Success/failure fixtures keep
their five-second command budget; timeout fixtures keep two seconds. A virtual-clock readiness test proves
one-second startup adds no fixed ancestry sleep. Gate waits are bounded and stop-file aware; helper
self-expiry remains 20 seconds.
The nested failure regression gates the inner drain and controls outer snapshots: the outer observer
sees a live session leader first, then its previously unseen orphan with the exited leader hidden.
Only the inner wait owner drains that orphan; the outer runner must complete without claiming it.
Contract tests also require unresolved sessions to fail at cleanup and reject reused leader births.

Cost performance and fair-scheduling corpora use exclusive initial fixture creation: the scanner only
reads after setup has closed each file. This avoids per-file atomic publication and durability work
without changing corpus contents or scan budgets. The shared atomic fixture writer remains available
for replacement and publication tests.

### Cost scanner CPU regressions

`CostUsageJsonl` finds complete physical LF spans with bounded libc `memchr` on Darwin, Glibc, and
Musl, using the same span algorithm with scalar LF search elsewhere. Borrowed pointers stay inside
the current `withUnsafeBytes` call; search counts and distances fit the existing 256 KiB read chunk.
Complete spans keep the original prefix-copy and flush path. Unfinished chunk suffixes still run the
original scalar JSON tail updater, preserving exact resumable state and EOF validation. CR bytes,
empty-line offsets, independent prefix/max limits, budgets, and cancellation/stop ordering are unchanged.

Persisted Codable checkpoints are a compatibility boundary, including unusual decoded counters.
Skipping tail updates requires a nonnegative line count, safe container-depth arithmetic for the span,
and nonnegative literal indices. Otherwise the same scalar updater runs before the existing flush;
this preserves its checked operations and state when the flush does not reset a negative line count.
Do not replace this guard with checkpoint normalization or a new corrupt-cache recovery policy.

`CostUsageJsonlDifferentialTests` in the portable `TestsLinux` target compares exact bytes, offsets,
sorted full Codable state, callback order, and error domain/code with the frozen e236a21b scalar scanner.
Its bounded default matrix covers every short-input split, threshold/chunk boundaries, mutations,
cross-version resumes, and safe unusual checkpoints. Keep that oracle frozen and the older scanner
oracle independently useful. Full optimized scratch parity must copy the final production source;
prototype results alone do not carry forward through formatting or edits. Scanner parity does not
establish pipeline performance; signed optimized builds and synthetic pipeline timing are separate proof.

The shared scanner remains a parser-hash input. Published `e0b0319de43e22d7` is the immediate tested
compatible predecessor because LF-span scanning preserves persisted semantics, including the priority
cursor changes in #3318. The earlier `7e293e8fc9e25700` and existing predecessors remain supported.
Native adoption retains rows and checkpoints while invalidating old connection receipts.
Pi/OMP still reparses once when the hash changes,
with and without a catalog; subsequent unchanged reads use the current cache. No pricing-key alias is added.

Profile the cost-scan queue separately from the main thread. A busy background scan that later settles
does not establish an infinite loop. Native timestamp conversion uses Foundation's modern ISO parser
for strict RFC3339 input, retaining the previous formatter's millisecond truncation and rounding.
Historical spellings and malformed input keep the formatter fallback. Claude reuses the parsed date
for local day projection only on the strict path.

`CostUsageTimestampTests` compares exact dates with the prior formatter and checks local days, DST,
deduplication, and dated pricing. `CostUsageTimestampOrderTests` and `CostUsageStoreCutoverTests` count
timestamp comparisons: a known ordered prefix needs only the append boundary and new events; unknown
prefixes get one cancellable validation. Keep these assertions deterministic rather than timing gates.
Run these alongside scanner, cancellation, bounded-progress, fork, and performance-gate suites with
the test harness's Keychain and credential-file isolation enabled.

An optimized synthetic check on 2026-08-30 compared main `5a18e8ee9` with this change: three cold
Claude scans of 20,000 messages (5,237,780 bytes) had median CPU time of 3.430 → 1.273 seconds and
wall time of 5.838 → 2.107 seconds, with identical emitted token/cost totals and daily output. This
measures ingestion through the public fetcher, not idle-app CPU or the entire Codex scan pipeline.

Native Codex scans carry an opaque receipt from load to save. `CostUsageStore` owns one decoded persisted
baseline and compact file/count metadata, releasing it on save, superseding loads, mutations, failures,
or scan exit (including cancellation and debounce). Abandoned receipts also release through the actor.
No raw historical SQL snapshot or transaction stays alive across JSONL scanning. Filesystem/device,
anchor, and pending catch-up reconciliation rerun for comparisons; decoded reuse never freezes them.

Reuse requires the same connection generation and database inode, SQLite's open-file identity check,
same-connection `data_version`, own `total_changes`, and schema/parser metadata. Observations bracket
a successfully committed short read transaction. Save checks again under `BEGIN IMMEDIATE`, after
unchanged-path retention; external changes request a rescan without overwriting current content.
Retention that rewrites identical metadata requires a fresh locked semantic comparison. Existing callers
without a receipt read a fresh baseline at save and cannot establish freshness back to an earlier load.

`CostUsageStoreReadWorkTests` counts full load/save cycles: an uncontended unchanged receipt cycle reads
one full snapshot and decodes each usage row once, with one freshness write and no aggregate grouping
visits. Synthetic interleavings cover writer races, mutations, retention, replacement and receipt lifetime.
Initial decoding, semantic equality, filesystem reconciliation, report generation and priority aggregation
still cost work proportional to retained history. These counters do not measure installed-app idle CPU;
refresh cadence, scan budgets, timestamp parsing and incremental-order validation are unchanged.

Claude/Vertex metadata classification searches decoded ASCII strings with case-folded bytes, keeping
the original Foundation lowercase/substring predicate for non-ASCII or noncontiguous strings. Check
the whole string for ASCII before matching; combining characters after a marker can affect the old
predicate. The recursive dictionary/array walk visits dictionaries inside arrays without recursing into nested arrays.
`CostUsageClaudeVertexClassifierTests` compares with the frozen old predicate and checks complete filtered
rows, persisted daily tokens/costs, and reports, including decoded JSON escapes, Unicode boundaries,
nested arrays, and false/numeric metadata flags.

`ClaudeJSONObject` shares a shallow decoded-container view between field extraction and classification;
the parser reuses its message view for primary detection and usage extraction. On Darwin, ASCII-keyed
objects retain immutable Foundation containers and use scoped CF bulk access and type dispatch. Only
JSONSerialization results and their decoded descendants enter that path; arbitrary objects and coerced
entries use Swift casts. CF bridging is Darwin-only, and retained owners outlive all borrowed pointers
and temporary allocations.
Empty containers require no pointer arithmetic. Unicode-keyed objects use the actual conditional
`[String: Any]` coercion at each object boundary, preserving canonical-key collapse and whole-object
mixed-key rejection. The walker visits only the resolved entries. Independent coercions can choose
different collision winners, so tests assert resolved-entry behavior rather than a deterministic winner.
Linux uses the same view and walker with portable Swift coercions, with no CF bridging or separate
pricing path. `ClaudeJSONObjectTests` also belongs to the portable CLI/core test target.

Claude parsing returns only rows and parsed bytes. The scan owns reconciliation across streaming chunks,
parent files and subagents, then builds persisted days from the stored row model; there is no discarded
parser-day aggregation or second normalization. Daily tests exercise the real cache/report boundary.
Removing the unused field in the shared scanner changes the generated native parser hash, while Codex
semantics remain unchanged. Published `494eee446bb2e5f9` is a tested compatible predecessor; existing
predecessors and store receipt logic remain intact. Pi/OMP pricing keys include this hash and therefore
reparse once under the existing invalidation contract, also tested with and without a catalog.

A second optimized synthetic check against main `354191af9` used three fresh-cache scans per provider
with 32–128 KiB text bodies. Median CPU decreased by 3–18% across Claude/Vertex cases (the 3% case is
small); a separate long-provider-string stress case decreased by 73–75%. The isolated decoded metadata
predicate used about half the CPU on ordinary nested metadata. Every daily token component and cost
matched, including the existing unset public request counts. Fixture generation was outside timing;
wall time was recorded separately under host load. These results do not measure idle-app CPU.

Claude and Vertex scans share one synchronous invocation-owned pricing resolver across full/append file
parsing, row normalization, and report repricing. It lazily snapshots the catalog, including an empty
sentinel for unavailable artifacts, at the existing changed-file and nonempty-report preparation points.
An exact report memo hit and an empty inventory with no rows do not load it. The internal standalone
parser now owns one snapshot per parse, optionally supplied explicitly; the cancellable parser takes
that owner directly. It does not reread pricing artifacts between rows.

Normalization and positive/negative catalog lookup memos use exact decoded UTF-8 keys, preserving
Unicode spelling, dated raw versus stored identities, and non-idempotent normalization. Each memo
retains at most 1,024 entries per invocation; after saturation, uncached inputs still resolve normally.
This bounds entry growth, not model-string bytes or scan work. Every row still selects its own dated
tariff and context tier and runs the existing monetary arithmetic. Historical pricing short-circuits
before model lookup. Independent scalar Pi/Cursor/direct pricing retains its uncached resolution path.
Both callers share one private tariff-selection helper whose nonescaping lazy lookup closure runs only
after historical selection. The scalar calls the original normalizer and lookup directly; the scan
resolver supplies memoized resolution. Both use the original monetary calculation.

DEBUG Claude scan metrics count normalization cache misses and actual catalog-model lookups with
positive/negative outcomes; the first lookup still normalizes internally. `repricedRows` continues to
count all rows. Measure through the synchronous scoped recorder because the public dispatch queue
does not inherit TaskLocal instrumentation. Resolver and scanner memo tests exercise cross-file reuse,
snapshot replacement, saturation, exact spelling, and report-only repricing against synthetic fixtures.
The shared pricing source changes the generated Codex parser hash, but Codex algorithms are unchanged;
`6366caa15c925349` remains an explicitly tested compatible predecessor.

### Adaptive refresh fixtures

Heuristics and timer tests seed disabled providers through `testSettingsStore(config:)`, which saves the
file-backed config before settings initialization. They do not replay a synchronous config write for each
provider toggle during setup. The seed preserves provider defaults and explicitly keeps OpenAI web access
off; an existing config would otherwise enable it. Reset-boundary tests then enable only the stubbed Codex
provider. Timer intervals, polling deadlines, and production persistence behavior remain unchanged.

### Claude session fixtures

Profile/reuse and overlapping-capture tests wait for the fixture's expected `Account:` response with idle
completion disabled; PTY command echo alone is not functional completion. The profile/reuse test keeps both
immediate responses and a controlled 0.5-second response delay, beyond the former 0.1-second idle window.
Capture budgets remain two seconds for profile/reuse and five seconds for overlap. Account, environment,
launch-count, isolation, and stale-artifact assertions remain independent of the completion condition.

### Codex credential fixtures

Ordinary tests deny Codex credential-file access at the Codex-owned I/O boundaries, before reads,
existence probes, or writes. Detection uses the actual process name/environment, independently of
the credential environment under test. `HOME`, `CODEX_HOME`, `XDG_DATA_HOME`, and
`CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS` do not authorize files. The disabled live-account test remains
disabled; neither `LIVE_TEST` nor Keychain permission alone bypasses this boundary.

Use `CodexCredentialFileAccess.withFixtureScope(.init(files: [...], roots: [...]))` for an explicitly
owned fixture. Synchronous and asynchronous forms restore the previous scope on return or throw.
Roots use path components, reject symlinks within the fixture, and never implicitly authorize all
of `/tmp`. The `CodexCredentialFixtures` test trait creates and cleans up one owned root per test;
credential/account fixtures allocate their homes under `CodexCredentialFixtures.root`. Promotion
and scoped-refresh containers share that helper. The trait also binds the existing dashboard-cache
URL override to its owned root, so cache reads, writes, and clears stay local to the test.
`_loadForUsageForTesting` adds only its explicit
home fixture to the current scope; configured external roots still need explicit authorization.
Pure parsers and `fingerprint(data:)` need no scope. Default managed-account and workspace-cache
stores use fresh temporary paths in tests; explicit file overrides retain their existing behavior.

Task-local scopes inherit through structured tasks, but not detached work. Capture the immutable
`fixtureScope` and explicitly re-enter it in a detached task when fixture access is required; lost
context fails closed. Never authorize a path just because it appears in an environment dictionary.

`Scripts/test.sh` exports `CODEXBAR_TEST_CODEX_FILE_ISOLATION=1` and removes inherited fixture grants.
Direct test commands that launch children should export the same signal. A child needing files must
receive `FixtureScope(files: ..., roots: ...).childEnvironment(base: ...)` naming only that child's
fixtures; this replaces any inherited grants without changing global environment state. The signal,
scope decoding, and denial are compiled in release builds too. `bash Scripts/test_codex_file_isolation_child.sh`
compiles the actual policy and detector with optimization and without `DEBUG`, then checks denied,
scoped-child, and non-test decisions against synthetic temporary files. It does not build or exercise
the complete release CLI, refresh a real account, or establish isolation for other providers.

The same runtime and inherited Codex-file isolation signal also redirects the scanner's default priority trace
database to a process-local, nonexistent temporary path before consulting the user home. Supplying a fixture
session root alone does not select a trace database. Tests exercising priority metadata should pass an explicitly
owned `codexTraceDatabaseURL`; these overrides and the production `~/.codex/logs_2.sqlite` default are unchanged.
The optimized child-policy proof above also verifies this fallback, independently of Keychain opt-ins.

### Provider session fixtures

Cursor, Augment, Factory, and Notion session stores select a process-local temporary directory under Swift Testing
or XCTest, before creating directories, loading saved files, or repairing permissions. The runtime guard is also
compiled in release builds; allowing real Keychain access does not disable this file isolation. Production filenames
and owner-only persistence remain unchanged.

Persistence tests should construct stores with an explicitly owned `fileURL` and clean up that fixture. Use fresh
writer/reader instances to prove disk reloads. The sharded runner exports `CODEXBAR_TEST_SESSION_FILE_ISOLATION=1`
for child processes; direct test commands that launch children should export it too. This covers these four default
session stores, not arbitrary file access or provider-owned credential databases.

`bash Scripts/test_provider_session_file_isolation.sh` compiles the actual path policy and runtime detector with
optimization and without `DEBUG`, then verifies inherited child isolation and unchanged production-relative paths
against fake Application Support files. It does not launch the app, read real sessions, or exercise a full release CLI.

### WebView ownership regressions

`OpenAIDashboardWebViewCacheTests` uses explicit nonpersistent stores and a DEBUG preparation seam to suspend
acquisitions without navigation. Controlled continuations exercise eviction/replacement, stale completion, timeout
retry, store-scoped invalidation, and lease cleanup after cache loss. Host assertions check one cleanup request and
registration with `WebKitTeardown`; they do not establish WebContent process termination or diagnose CPU/RSS incidents.
The existing headless CI guards remain in place for these AppKit tests. The suite also contains older persistent-store
factory tests; exclude those when running a nonpersistent-only focused check.

### CI Aggregate Contract

The `lint-build-test` check in `.github/workflows/ci.yml` keeps its existing name and requires successful lint,
change detection, and the full `build-linux-cli` glibc matrix (x86_64 and ARM64 build, tests, and smoke checks).
Glibc Linux has no path or draft skip: failure, cancellation, skipped, empty, missing, or unknown matrix results
fail verification. macOS tests and the musl build may skip only when their path gates allow it; required macOS
tests deferred for a draft still leave the aggregate incomplete. Whole-workflow cancellation retains the existing
`always() && !cancelled()` condition, so the verifier does not run in that case.

`Scripts/test_ci_path_gate.sh` checks these result combinations and the workflow's Linux dependency and eighth
verifier argument. `CodexBarLinuxTests` includes the portable `AntigravityLocalhostSessionLifetimeTests` suite on
both macOS and Linux. It checks session reuse and concurrent synthetic loopback failures without credentials;
this coverage does not establish or fix the cause of Linux dispatch crashes.

### Format Code
```bash
swiftformat Sources Tests
swiftlint --strict
```

## Distribution

### Local Development Build
```bash
./Scripts/package_app.sh
# Creates: CodexBar.app with ad-hoc signing by default
```

### Release Build (Notarized)
```bash
./Scripts/sign-and-notarize.sh
# Creates: CodexBar-<version>.zip and CodexBar-<version>.dSYM.zip
```

See `docs/RELEASING.md` for full release process.

## Troubleshooting

### App Won't Launch
```bash
# Check crash logs
ls -lt ~/Library/Logs/DiagnosticReports/CodexBar* | head -5

# Check Console.app for errors
# Filter: process:CodexBar
```

### Keychain Prompts Keep Appearing
Confirm the prompt's requested item and requesting binary, then check for another running or installed CodexBar copy.
Do not validate a fix by querying the real Keychain from routine tests. See [Keychain prompts](keychain-prompts.md).

### Cookies Not Refreshing
1. Check the browser is supported by the Augment provider metadata
2. Verify you're logged into Augment in that browser
3. Check Preferences → Providers → Augment → Cookie source is "Automatic"
4. Enable debug logging and check Console.app

### Main-Thread Hangs

Debug builds start the hang watchdog automatically. To diagnose a release build,
enable it explicitly and restart CodexBar:

```bash
defaults write com.steipete.codexbar debugMainThreadHangWatchdog -bool true
```

Hangs are written to the app log. Hangs over two seconds also request a process
sample under `~/Library/Logs/CodexBar/`. Disable the release opt-in with:

```bash
defaults delete com.steipete.codexbar debugMainThreadHangWatchdog
```

## Architecture Notes

### Menu Bar App Pattern
- No dock icon (LSUIElement = true)
- Status item only (NSStatusBar)
- SwiftUI for preferences, AppKit for menu
- Hidden 1×1 window keeps SwiftUI lifecycle alive

### Cookie Management
- Automatic browser import via SweetCookieKit
- Keychain cache for some imported browser cookies and OAuth/device-flow credentials
- `~/.codexbar/config.json` for provider settings, manual cookies, and stored API keys
- Manual override for debugging
- Browser-cookie import when cached sessions need refresh

### Usage Polling
- Background timer (configurable frequency)
- Parallel provider fetches
- First failure can be suppressed when prior data exists
- WidgetKit snapshot for macOS widgets
