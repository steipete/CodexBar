# Native ledger experiment: reproducible evidence

The public fixture contains synthetic histories only. The macOS packaged CLI and the installed Ubuntu
CLI were run independently with an identical fixed UTC window, with the Ubuntu export collected through
real SSH. Personal histories, live usage counts, host addresses and credentials are not part of this file.

## Native collection and transport

For each provider, the local source had one request and an identical copied file. The SSH source had that
request, its copied file and a distinct request of the same size. Each request contained 100 input tokens
and 10 output tokens. Codex also contained 20 cache-read tokens, already included in its native input.
Claude contained zero cache-read and cache-write tokens.

The native Codex records used `session_meta`, `turn_context` and `token_usage_record`, with explicit
session/turn/response IDs and request/thread usage. The native Claude records used completed `assistant`
messages with explicit session/message/request IDs and `claude-sonnet-4-20250514`. The JSONL assistant
entries use the compact form written by the native client.

The shipped entry points were invoked as follows, with each fixture root supplied only to that process:

```sh
env CODEX_HOME=<fixture-codex-root> CLAUDE_CONFIG_DIR=<fixture-claude-root> \
  CodexBarCLI cost --provider codex --ledger-only --format json --days 1 \
  --ledger-time-zone UTC --ledger-end 1791648000000

ssh <trusted-test-host> env CODEX_HOME=<remote-fixture-codex-root> \
  CLAUDE_CONFIG_DIR=<remote-fixture-claude-root> \
  codexbar cost --provider codex --ledger-only --format json --days 1 \
  --ledger-time-zone UTC --ledger-end 1791648000000
```

The same commands were repeated with `--provider claude`.

| Provider | Local native export | Actual SSH native export | Production merger expectation |
| --- | --- | --- | --- |
| Codex | 1 record, 110 tokens | 2 records, 220 tokens | 220 tokens, 1 duplicate removed |
| Claude | 1 record, 110 tokens | 2 records, 220 tokens | 220 tokens, 1 duplicate removed |

The captured numeric ledgers are committed in
[`native-ssh-proof.json`](../TestsLinux/Fixtures/UsageLedger/native-ssh-proof.json).
`UsageLedgerMergeTests.captured native Mac and real SSH fixture exports combine through the production merger`
decodes those exact captures and exercises the production merge for both providers. Network collection
is already captured; the regression itself needs no network or credentials.

## Contradictions, pricing and compatibility

The focused native exporter regressions exercise copied and same-file Codex request contradictions,
completed Claude copy contradictions, zero-count copies, model redaction, overflow, valid cumulative
streaming, incomplete-to-complete normalization and exact fractional-millisecond boundaries. A clean
observation from another host cannot revive a native conflict, including when its numeric row was omitted.

The Codex installed-pricing regression uses a separate synthetic models.dev catalog with a $2/million
uncached input rate: 100,000 input tokens cost $0.20. It checks unchanged catalog bytes and that no cost
database is created in the pricing root. The scan database remains disposable.

The stable upgrade regression uses the actual v0.74.0/main parser fingerprint `f406dae284de4a55`. It removes
the source log before adopting the compatible database, verifies saved billing/pricing rows, retained
reports and checkpoints, asserts zero destructive rebuilds, then resumes the persisted cursor.

## Native UI trial

Private live trials of the packaged CLI and the native manual panel exercised both providers against the
selected SSH host. The panel was checked for disabled controls during collection, cancellation restoration,
clearing previous results on provider reselection, partial coverage and expanded source diagnostics.
Private results remain outside this PR; the public screenshot shows the empty controls only.

Debug `--usage-ledger-preview` enters the real panel in a standalone window before ordinary settings,
provider startup or shared dashboard cache access. The full application still integrates that same panel
in Usage & Spend. The initial trial used the regular dashboard before this safer preview was added;
there is no pre-trial cache snapshot, so preservation of that initial local cache cannot be claimed.

This evidence demonstrates the bounded native-history operation. It does not establish exhaustive
account-wide usage, an invoiced dollar amount, or maintainer approval of the proposed product contract.
