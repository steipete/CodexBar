# StoreStress

Adversarial crash, contention, corpus-rebuild, WAL, and descriptor harness for the SQLite-backed
`CostUsageStore`. It is a separate package so its internal test access never enters normal CodexBar builds.

Build the optimized harness from this directory:

```sh
swift build -c release -Xswiftc -enable-testing
```

Run `swift run -c release -Xswiftc -enable-testing StoreStress --` without arguments to print the available
subcommands. Every store/cache argument should point at a disposable temporary directory. `rebuild` and
`incremental` accept an optional sessions root, which makes it possible to measure a read-only corpus snapshot
without writing to the real Codex session or CodexBar cache directories.

On macOS, compare separate `memory <cacheRoot> full` and `memory <cacheRoot> lean`
processes against the same disposable cache copy. The output includes physical
footprint in MiB, a sampled peak, and loaded file, usage-row, and token-snapshot
counts. The lean mode exercises the Workspaces indexer's cache read; both modes
should retain the same usage rows while lean omits token snapshots. `memory
<cacheRoot> none` measures process overhead without opening the cache. These
measurements do not represent steady-state menu-bar memory.

Generate a contained corpus with real synthetic source files and typed cached rows before comparing revisions:

```sh
stress_bin="$(swift build -c release -Xswiftc -enable-testing --show-bin-path)/StoreStress"
TZ=UTC "$stress_bin" fixture /tmp/codexbar-memory-fixture 256 1000
TZ=UTC "$stress_bin" memory /tmp/codexbar-memory-fixture/cache lean
```

`fixture` requires a new directory and accepts up to 1,000 files with 1,000 rows each. Its sessions, cache, and
nonexistent trace-database path all stay inside that directory. Keep the generated source files present and use
the same timezone for generation and every probe. Verify file/row counts in the output, and measure each mode
in separate processes at least three times. For larger cases, use `1000 1000`; never point the generator at an
existing account or cache directory.
