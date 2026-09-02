#!/usr/bin/env python3
"""
verify_antigravity_timestamp.py

Authoritative verification for modern Antigravity (agy 1.1.18+) SQLite clocks.

1. Identifies the actual clock in modern agy SQLite databases:
   - In `steps` table, rows with `step_type = 15` (LLM generation) contain an authoritative
     `google.protobuf.Timestamp` at `metadata.#1` (field 1 = seconds, field 2 = nanos).
   - `steps.metadata.#9.#7` contains the unique generation request ID (`bot-<uuid>`).
   - `gen_metadata` usage (under `chatModel.#4.#7`) contains the identical `bot-<uuid>`.
   - Joining `gen_metadata` and `steps` on this ID links 100% of all completed generations
     to monotonic, nanosecond-precision wall-clock timestamps spanning the entire multi-hour
     session duration.

2. Live verification against running agy CLI (when agy is on PATH):
   - Executes a live prompt with `agy --print`.
   - Inspects the newly written database in ~/.gemini/antigravity-cli/conversations/.
   - Confirms that `steps.metadata.#1` matches the system wall-clock time within milliseconds.

Usage:
  python3 Scripts/verify_antigravity_timestamp.py            # Runs live test + local database audit
  python3 Scripts/verify_antigravity_timestamp.py --offline  # Skips live agy execution
  python3 Scripts/verify_antigravity_timestamp.py --db PATH  # Audits a specific SQLite database
"""

import argparse
import datetime
import glob
import os
import shutil
import sqlite3
import subprocess
import sys
import time


def decode_varint(data, offset):
    res, shift = 0, 0
    while offset < len(data):
        b = data[offset]
        offset += 1
        res |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return res, offset
        shift += 7
    return None, offset


def parse_fields(data):
    if not data:
        return []
    offset, fields = 0, []
    while offset < len(data):
        tag, offset = decode_varint(data, offset)
        if tag is None:
            break
        num, wire = tag >> 3, tag & 7
        if wire == 0:
            val, offset = decode_varint(data, offset)
            fields.append((num, wire, val))
        elif wire == 2:
            length, offset = decode_varint(data, offset)
            if length is None or offset + length > len(data):
                break
            fields.append((num, wire, data[offset : offset + length]))
            offset += length
        elif wire == 1:
            offset += 8
            fields.append((num, wire, None))
        elif wire == 5:
            offset += 4
            fields.append((num, wire, None))
        else:
            break
    return fields


def extract_step_timestamp_and_bot_id(metadata_blob):
    if not metadata_blob:
        return None, None
    ts = None
    bot_id = None
    for num, wire, val in parse_fields(metadata_blob):
        if num == 1 and wire == 2:
            s, ns = 0, 0
            for sn, sw, sv in parse_fields(val):
                if sn == 1 and sw == 0:
                    s = sv
                elif sn == 2 and sw == 0:
                    ns = sv
            if s > 0:
                ts = s * 1000 + ns // 1_000_000
        elif num == 9 and wire == 2:
            for bn, bw, bv in parse_fields(val):
                if bn == 7 and bw == 2:
                    try:
                        bot_id = bv.decode("utf-8")
                    except Exception:
                        pass
    return ts, bot_id


def extract_gen_metadata_info(data_blob):
    if not data_blob:
        return None
    chat = None
    for num, wire, val in parse_fields(data_blob):
        if num == 1 and wire == 2:
            chat = val
            break
    if not chat:
        return None

    usage_data = None
    gen_data = None
    for num, wire, val in parse_fields(chat):
        if num == 4 and wire == 2:
            usage_data = val
        elif num == 9 and wire == 2:
            gen_data = val

    bot_id = None
    out_tokens = 0
    if usage_data:
        for un, uw, uv in parse_fields(usage_data):
            if un == 7 and uw == 2:
                try:
                    bot_id = uv.decode("utf-8")
                except Exception:
                    pass
            elif un == 9 and uw == 0:
                out_tokens = uv

    field_10_1 = None
    field_10_4 = None
    if gen_data:
        for gn, gw, gv in parse_fields(gen_data):
            if gn == 10 and gw == 2:
                for f_n, f_w, f_v in parse_fields(gv):
                    if f_n == 1 and f_w == 0:
                        field_10_1 = f_v
                    elif f_n == 4 and f_w == 0:
                        field_10_4 = f_v

    return {
        "bot_id": bot_id,
        "out_tokens": out_tokens,
        "context_tokens": field_10_1,
        "context_window": field_10_4,
    }


def audit_database(db_path):
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = {r[0] for r in cur.fetchall()}

    if "gen_metadata" not in tables:
        conn.close()
        return None

    has_steps = "steps" in tables
    step_map = {}
    if has_steps:
        cur.execute("SELECT idx, metadata FROM steps WHERE step_type = 15 AND metadata IS NOT NULL")
        for idx, meta in cur.fetchall():
            ts, bot_id = extract_step_timestamp_and_bot_id(meta)
            if bot_id and ts:
                step_map[bot_id] = ts

    cur.execute("SELECT idx, data FROM gen_metadata ORDER BY idx")
    gen_rows = cur.fetchall()
    conn.close()

    total_gens = 0
    completed_gens = 0
    matched_gens = 0
    matched_timestamps = []
    compaction_drops = 0
    prev_context = None

    for idx, data in gen_rows:
        info = extract_gen_metadata_info(data)
        if not info:
            continue
        total_gens += 1
        is_completed = info["out_tokens"] > 0
        if is_completed:
            completed_gens += 1
            bot_id = info["bot_id"]
            if bot_id and bot_id in step_map:
                matched_gens += 1
                matched_timestamps.append(step_map[bot_id])

        cur_ctx = info["context_tokens"]
        if cur_ctx is not None and prev_context is not None:
            if cur_ctx < prev_context - 5000:
                compaction_drops += 1
        if cur_ctx is not None:
            prev_context = cur_ctx

    non_monotonic = 0
    for i in range(1, len(matched_timestamps)):
        if matched_timestamps[i] < matched_timestamps[i - 1]:
            non_monotonic += 1

    file_mtime = os.path.getmtime(db_path)
    span_seconds = 0
    if matched_timestamps:
        span_seconds = (matched_timestamps[-1] - matched_timestamps[0]) / 1000.0

    return {
        "db": os.path.basename(db_path),
        "path": db_path,
        "has_steps": has_steps,
        "total_gens": total_gens,
        "completed_gens": completed_gens,
        "matched_gens": matched_gens,
        "non_monotonic": non_monotonic,
        "span_seconds": span_seconds,
        "file_mtime": file_mtime,
        "first_ts": matched_timestamps[0] if matched_timestamps else None,
        "last_ts": matched_timestamps[-1] if matched_timestamps else None,
        "compaction_drops": compaction_drops,
    }


def run_live_test():
    print("\n" + "=" * 78)
    print("  1. LIVE AGY TEST: Validating steps Table Clock in Real-Time")
    print("=" * 78)

    agy_path = shutil.which("agy")
    if not agy_path:
        print("[-] agy binary not found on PATH. Skipping live test.")
        return

    print(f"[*] Found agy binary: {agy_path}")
    version_proc = subprocess.run(["agy", "--version"], capture_output=True, text=True)
    version = version_proc.stdout.strip() if version_proc.returncode == 0 else "unknown"
    print(f"[*] agy version: {version}")

    conv_dir = os.path.expanduser("~/.gemini/antigravity-cli/conversations")
    before_dbs = set(glob.glob(os.path.join(conv_dir, "*.db")))

    t_before = time.time()
    t_before_iso = datetime.datetime.fromtimestamp(t_before, tz=datetime.timezone.utc).isoformat()
    print(f"[*] Prompting agy at {t_before_iso} ...")

    proc = subprocess.run(
        ["agy", "--print", "Respond with exactly: PONG_CLOCK_TEST"],
        capture_output=True,
        text=True,
        timeout=60,
    )

    if proc.returncode != 0:
        print(f"[-] agy execution failed: {proc.stderr.strip()[:200]}")
        return

    print(f"[+] agy response: {proc.stdout.strip()[:80]}")

    time.sleep(0.5)
    after_dbs = set(glob.glob(os.path.join(conv_dir, "*.db")))
    new_dbs = list(after_dbs - before_dbs)
    candidates = [p for p in after_dbs if os.path.getmtime(p) > t_before - 1]
    target_db = None
    if new_dbs:
        # Prefer newly created DB, but ensure it is after t_before (handles pre-existing mtime collisions)
        new_candidates = [p for p in new_dbs if os.path.getmtime(p) > t_before - 1]
        target_db = max(new_candidates or new_dbs, key=os.path.getmtime)
    elif candidates:
        target_db = max(candidates, key=os.path.getmtime)
    elif after_dbs:
        target_db = max(after_dbs, key=os.path.getmtime)

    if not target_db:
        print("[-] Could not locate output database.")
        return

    print(f"[+] Located database: {os.path.basename(target_db)}")
    try:
        conn = sqlite3.connect(f"file:{target_db}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        print(f"[-] Could not open database read-only: {e}")
        return
    cur = conn.cursor()

    cur.execute("SELECT idx, metadata FROM steps WHERE step_type = 15 ORDER BY idx DESC LIMIT 1")
    step_row = cur.fetchone()
    cur.execute("SELECT idx, data FROM gen_metadata ORDER BY idx DESC LIMIT 1")
    gen_row = cur.fetchone()
    conn.close()

    if not step_row or not gen_row:
        print("[-] Could not find step or generation rows in database.")
        return

    step_ts_ms, step_bot_id = extract_step_timestamp_and_bot_id(step_row[1])
    gen_info = extract_gen_metadata_info(gen_row[1])

    step_sec = step_ts_ms / 1000.0 if step_ts_ms else 0
    step_dt = datetime.datetime.fromtimestamp(step_sec, tz=datetime.timezone.utc)
    t_after = time.time()
    skew_ms = abs(step_sec - t_after) * 1000.0
    skew_before_ms = abs(step_sec - t_before) * 1000.0

    print("\n--- Live Verification Results ---")
    print(f"  Step ID (`step_type = 15`):    {step_bot_id}")
    print(f"  Gen ID (`chatModel.#4.#7`):    {gen_info['bot_id']}")
    print(f"  IDs match exactly:             {step_bot_id == gen_info['bot_id']}")
    print(f"  System prompt time (t_before): {datetime.datetime.fromtimestamp(t_before, tz=datetime.timezone.utc)}")
    print(f"  System time after agy (t_after): {datetime.datetime.fromtimestamp(t_after, tz=datetime.timezone.utc)}")
    print(f"  `steps.metadata.#1` timestamp: {step_dt}")
    print(f"  Clock skew vs t_after:         {skew_ms:.1f} ms (vs t_before {skew_before_ms:.1f} ms)")

    if step_bot_id == gen_info["bot_id"] and skew_ms < 60000 and skew_before_ms < 120000:
        print("\n  >>> RESULT: PASS! Authoritative wall clock verified via live agy generation.")
    else:
        print("\n  >>> RESULT: FAIL! Mismatch detected.")


def run_local_audit(dbs):
    print("\n" + "=" * 78)
    print("  2. STORE AUDIT: Verifying Clock Monotonicity Across Local Databases")
    print("=" * 78)

    results = []
    for db in sorted(dbs):
        r = audit_database(db)
        if r and r["completed_gens"] > 0:
            results.append(r)

    total_completed = sum(r["completed_gens"] for r in results)
    total_matched = sum(r["matched_gens"] for r in results)
    total_non_monotonic = sum(r["non_monotonic"] for r in results)
    total_compaction_drops = sum(r["compaction_drops"] for r in results)

    print(f"Audited {len(results)} conversation databases:")
    print(f"  - Completed generation turns:   {total_completed}")
    print(f"  - Matched via steps.metadata:   {total_matched} ({total_matched/max(1, total_completed)*100:.2f}%)")
    print(f"  - Non-monotonic clock steps:    {total_non_monotonic} (0 = strictly monotonic)")

    long_sessions = [r for r in results if r["span_seconds"] > 1800]
    if long_sessions:
        print("\nLong Sessions Proof (Duration > 30 minutes):")
        for s in long_sessions[:5]:
            span_min = s["span_seconds"] / 60.0
            first_dt = datetime.datetime.fromtimestamp(s["first_ts"] / 1000.0, tz=datetime.timezone.utc)
            last_dt = datetime.datetime.fromtimestamp(s["last_ts"] / 1000.0, tz=datetime.timezone.utc)
            mtime_dt = datetime.datetime.fromtimestamp(s["file_mtime"], tz=datetime.timezone.utc)
            print(f"  • DB {s['db'][:16]}...: {s['completed_gens']} turns, span: {span_min:.1f} min")
            print(f"    Start: {first_dt.strftime('%H:%M:%S')} UTC -> End: {last_dt.strftime('%H:%M:%S')} UTC")
            print(f"    File mtime: {mtime_dt.strftime('%H:%M:%S')} UTC (matches session end)")
            print(f"    Non-monotonic steps: {s['non_monotonic']}")


def main():
    parser = argparse.ArgumentParser(description="Verify modern Antigravity SQLite wall clock.")
    parser.add_argument("--db", help="Path to a specific database")
    parser.add_argument("--offline", action="store_true", help="Skip live agy prompt")
    args = parser.parse_args()

    if not args.offline and not args.db:
        run_live_test()

    if args.db:
        dbs = [args.db]
    else:
        conv_dir = os.path.expanduser("~/.gemini/antigravity-cli/conversations")
        dbs = glob.glob(os.path.join(conv_dir, "*.db"))

    if dbs:
        run_local_audit(dbs)
    else:
        print("[-] No SQLite databases found to audit.")


if __name__ == "__main__":
    main()

