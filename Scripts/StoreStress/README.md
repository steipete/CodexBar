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
