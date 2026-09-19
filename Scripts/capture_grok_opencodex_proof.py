#!/usr/bin/env python3
"""Capture real OpenCodex usage-writer output using its isolated upstream fixtures."""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opencodex-root", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()
    root = args.opencodex_root.resolve()
    expected = "146ed679c9633e5d68726217fcadc8e0b107339b"
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()
    if head != expected or dirty:
        parser.error("Use a clean OpenCodex checkout at " + expected)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    ledger = output / "usage.jsonl"
    source = root / "tests/server/server-xai-oauth-401-replay.test.ts"
    original = source.read_text()
    captured_test = original.replace(
        "mkdtempSync, readFileSync}",
        "mkdtempSync, readFileSync, existsSync, appendFileSync}",
        1,
    ).replace(
        "afterEach(() => {",
        "afterEach(() => {\n  if (existsSync(usageLogPath())) appendFileSync("
        + json.dumps(str(ledger)) + ", readFileSync(usageLogPath()));",
        1,
    ).replace(
        "return originalFetch(input, init);",
        'throw new Error("Unexpected upstream request in isolated producer proof");',
    )
    captured_test = re.sub(
        r'from "(\.[^"]+)"',
        lambda match: "from " + json.dumps(str((source.parent / match[1]).resolve())),
        captured_test,
    )
    test_file = output / "producer-proof.test.ts"
    test_file.write_text(captured_test)
    bun = root / "node_modules/.bin/bun"
    version = subprocess.check_output([str(bun), "--version"], cwd=root, text=True).strip()
    if version != "1.4.0":
        parser.error("Use repository-pinned Bun 1.4.0")
    with (output / "terminal.log").open("w") as terminal:
        subprocess.run(
            [str(bun), "test", str(test_file), "--test-name-pattern",
             "401 then 200 performs one refresh and one replay|native Chat records canonical API-key provenance"],
            cwd=root, stdout=terminal, stderr=subprocess.STDOUT, check=True,
        )
    raw = ledger.read_bytes()
    rows = [json.loads(line) for line in raw.splitlines()]
    assert len(rows) == 2
    assert all(secret not in raw for secret in [
        b"rejected-access", b"fresh-access", b"initial-refresh", b"xai-test-account", b"Bearer ",
    ])
    attempts = [attempt for row in rows for attempt in row["attempts"]]
    assert {row["credentialSource"] for row in attempts} == {"grok-oauth", "xai-api-key"}
    result = {
        "producerRepository": "https://github.com/lidge-jun/opencodex",
        "producerCommit": head,
        "bunVersion": version,
        "upstream": "isolated fixtures; no live provider requests",
        "sha256": hashlib.sha256(raw).hexdigest(),
        "rows": len(rows),
        "attempts": [{key: row[key] for key in [
            "credentialSource", "adapter", "sendCount", "totalTokens",
        ]} for row in attempts],
    }
    (output / "capture.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
