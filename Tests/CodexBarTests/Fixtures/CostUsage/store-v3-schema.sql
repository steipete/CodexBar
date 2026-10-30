-- CodexBar 0.81.0 base-3 schema, retained to verify in-place upgrades.
    CREATE TABLE meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );
    CREATE TABLE scan_metadata (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload BLOB NOT NULL
    );
    CREATE TABLE files (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        inode INTEGER,
        mtime_ms INTEGER NOT NULL,
        size INTEGER NOT NULL,
        parsed_bytes INTEGER,
        anchor_indexed_bytes INTEGER,
        anchor_window_start INTEGER,
        anchor_sha256 TEXT,
        scan_state BLOB NOT NULL,
        scan_target_size INTEGER,
        scan_complete INTEGER NOT NULL,
        session_id TEXT,
        coverage_since_day TEXT,
        coverage_until_day TEXT,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX files_path_idx ON files(path);
    CREATE INDEX files_session_idx ON files(session_id);
    CREATE INDEX files_coverage_idx ON files(coverage_since_day, coverage_until_day);
    CREATE INDEX files_updated_idx ON files(updated_at_ms);
    CREATE TABLE token_snapshots (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        event_index INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        timestamp_ms INTEGER,
        day TEXT,
        last_input INTEGER,
        last_cached INTEGER,
        last_output INTEGER,
        last_reasoning INTEGER,
        total_input INTEGER,
        total_cached INTEGER,
        total_output INTEGER,
        total_reasoning INTEGER,
        end_offset INTEGER,
        PRIMARY KEY(file_id, event_index)
    );
    CREATE INDEX token_snapshots_day_idx ON token_snapshots(day);
    CREATE INDEX token_snapshots_timestamp_idx ON token_snapshots(file_id, timestamp_ms, event_index);
    CREATE TABLE usage_rows (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        row_index INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(file_id, row_index)
    );
    CREATE INDEX usage_rows_file_idx ON usage_rows(file_id, row_index);
    CREATE TABLE file_day_aggregates (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        day TEXT NOT NULL,
        model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        cached_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        reasoning_tokens INTEGER NOT NULL,
        request_count INTEGER NOT NULL,
        authoritative_cost_nanos INTEGER NOT NULL,
        standard_input_tokens INTEGER NOT NULL,
        standard_cached_tokens INTEGER NOT NULL,
        standard_output_tokens INTEGER NOT NULL,
        priority_input_tokens INTEGER NOT NULL,
        priority_cached_tokens INTEGER NOT NULL,
        priority_output_tokens INTEGER NOT NULL,
        standard_tokens INTEGER NOT NULL,
        priority_tokens INTEGER NOT NULL,
        PRIMARY KEY(file_id, day, model)
    );
    CREATE INDEX file_day_aggregates_day_idx ON file_day_aggregates(day);
    CREATE INDEX file_day_aggregates_model_day_idx ON file_day_aggregates(model, day);
    CREATE TABLE day_aggregates (
        day TEXT NOT NULL,
        model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        cached_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        reasoning_tokens INTEGER NOT NULL,
        request_count INTEGER NOT NULL,
        authoritative_cost_nanos INTEGER NOT NULL,
        standard_input_tokens INTEGER NOT NULL,
        standard_cached_tokens INTEGER NOT NULL,
        standard_output_tokens INTEGER NOT NULL,
        priority_input_tokens INTEGER NOT NULL,
        priority_cached_tokens INTEGER NOT NULL,
        priority_output_tokens INTEGER NOT NULL,
        standard_tokens INTEGER NOT NULL,
        priority_tokens INTEGER NOT NULL,
        PRIMARY KEY(day, model)
    );
    CREATE INDEX day_aggregates_day_idx ON day_aggregates(day);
    CREATE INDEX day_aggregates_model_idx ON day_aggregates(model);
    CREATE INDEX day_aggregates_model_day_idx ON day_aggregates(model, day);
    CREATE TABLE fork_lineage (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        session_id TEXT,
        forked_from_id TEXT,
        fork_timestamp TEXT,
        dependency_key TEXT,
        subagent_state BLOB,
        accounting_state BLOB
    );
    CREATE INDEX fork_lineage_parent_idx ON fork_lineage(forked_from_id);
    CREATE TABLE buffered_lines (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        line_index INTEGER NOT NULL,
        ordinal INTEGER,
        end_offset INTEGER,
        payload BLOB NOT NULL,
        PRIMARY KEY(file_id, kind, line_index)
    );
    CREATE INDEX buffered_lines_file_idx ON buffered_lines(file_id, kind, line_index);
    CREATE TABLE discovery_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload BLOB NOT NULL
    );
    CREATE TABLE lookback_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload BLOB NOT NULL
    );
    CREATE TABLE accumulators (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        event_count INTEGER NOT NULL,
        next_usage_row_index INTEGER,
        counted_input INTEGER,
        counted_cached INTEGER,
        counted_output INTEGER,
        counted_reasoning INTEGER,
        baseline_input INTEGER,
        baseline_cached INTEGER,
        baseline_output INTEGER,
        baseline_reasoning INTEGER,
        watermark_input INTEGER,
        watermark_cached INTEGER,
        watermark_output INTEGER,
        watermark_reasoning INTEGER,
        saw_divergent INTEGER NOT NULL,
        saw_interleaved INTEGER NOT NULL,
        seen_raw_totals BLOB NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX accumulators_updated_idx ON accumulators(updated_at_ms);
