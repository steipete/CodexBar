---
summary: "Hermes Agent local SQLite token and cost history support."
read_when:
  - Checking Hermes Agent token usage in CodexBar
  - Troubleshooting Hermes local usage discovery
---

# Hermes

CodexBar reads Hermes Agent's local, read-only SQLite session store and exposes token usage in
Usage & Spend. The default location is `~/.hermes/state.db`; set `HERMES_HOME` when Hermes uses a
different home directory. Profile databases under `profiles/*/state.db` are included and duplicate
session IDs are counted once.

The reader uses Hermes' canonical token total:

`input_tokens + output_tokens + cache_read_tokens + cache_write_tokens`

Reasoning tokens are reported as a subset of output and are not added again. The two cumulative
tables are reconciled so auxiliary model rows do not double-count the session aggregate. API call
counts come from `api_call_count`; message counts are never treated as API calls.

Costs retain the producer's actual, estimated, included, or unknown state. List-price estimates are
marked as estimates, included usage remains a known zero, and unknown pricing is left unpriced.
Hermes stores cumulative counters, so daily buckets use the latest `last_seen`/`last_activity_at`
observation for each row; they are not invoice-grade per-day deltas. History is bounded and read in
a SQLite transaction; an incomplete or oversized store is surfaced as partial coverage rather than a
confirmed zero. The reader expects the current Hermes `sessions` and `session_model_usage` columns;
schema drift is reported as partial coverage instead of being silently guessed.
