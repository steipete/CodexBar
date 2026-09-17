# SSH Priority/Fast pricing regression

Implementation: `81da9ad7f5fb4be2e1d647a208d00b8fd7666b02`. Verification date: 2026-09-17. Mac toolchain: Swift 6.3.2.

The combined scan previously rejected retained Priority aggregates and relevant local trace evidence. It now reads the normal ledger without migration or writes, carries row-owned pricing across exact session copies/prefixes, scopes local trace evidence by session and turn, and rebuilds the native Standard/Priority report with the frozen Mac pricing context. Ambiguous ownership and unreconstructable evidence still fail closed.

## Verification

- Targeted regression run: 109 tests in 5 suites passed, covering joint accounting, native priority parsing, UI-store publication, and architecture checks.
- Cache adoption and architecture follow-up: 118 tests in 2 suites passed, including the previous parser generation.
- `make check`: passed, zero SwiftLint violations across 2,350 files.
- `make test`: 108/108 groups passed; test summaries report 11,247 tests, with 0 failures, retries or timeouts.
- `git diff --check`: passed.
- Independent read-only source review: passed after addressing trace-owner collisions, completion-model ownership, skipped state-event identity, and resolver/cursor consistency.

Tests include a ledger produced by the real native scanner with Fast evidence, followed by joint scans both before and after trace removal. Other cases cover identical copies, longer remote suffixes, independent sessions reusing turn IDs, cross-window requests, unknown prices, invalid identity, conflicting trace owners, and cancellation. The normal synthetic ledger remains byte-for-byte unchanged.

## Real SSH smoke

A small executable linked against the newly built Core objects invoked the public `CodexCombinedCostFetcher.load` and the newly built production CLI transfer guardian. It connected from the Mac to the existing xiemac-hosted Linux container, using a dedicated temporary synthetic Codex home. No real Codex history was scanned.

Synthetic Standard prices were $2/M input, $0.50/M cached input, and $8/M output. Each 110-token increment (100 input, including 20 cached, and 10 output) costs $0.00025 at Standard; the native gpt-5.4 API Fast multiplier makes it $0.00050.

- A shared local/remote session contains one common prefix and one remote suffix: 220 Priority tokens, counted once per increment.
- An independent remote session reuses the same turn ID: 110 Standard tokens.
- Observed combined result: **330 tokens, $0.00125**, with the expected 220/110 tier split.
- Synthetic local JSONL and trace hashes were unchanged; no ordinary cache was created. The request directory was empty before return, and the remote fixture was removed after the run.

See [machine-readable smoke receipt](codex-ssh-priority-fix.json).

This run validates the real SSH collector and joint accounting engine. The native menu-bar UI and Linux Swift build were not rerun for this fix; earlier receipts describe those checks on their own named commits. The installed production App and production CLIs were not replaced.
