from pathlib import Path
import argparse
import datetime
import errno
import json
import re
import subprocess

parser = argparse.ArgumentParser(description="Measure an isolated macOS CLI's Claude artifact writes")
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True, help="New directory for synthetic fixtures and evidence")
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
binary = args.binary.resolve()
subprocess.run([
    "/usr/bin/clang", "-dynamiclib", "-O2",
    str(Path(__file__).with_name("claude-artifact-write-observer.c")),
    "-o", str(root / "cli-write-observer.dylib"),
], check=True)
base = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).replace(
    hour=8, minute=0, second=0, microsecond=0)


def event(index):
    return json.dumps({
        "type": "assistant",
        "timestamp": (base + datetime.timedelta(seconds=index)).isoformat().replace("+00:00", "Z"),
        "requestId": f"request-{index}",
        "message": {"id": f"message-{index}", "model": "claude-sonnet-4-20250514",
                    "usage": {"input_tokens": 10, "output_tokens": 5}},
    }, separators=(",", ":")) + "\n"


results = []
for full in (True, False):
    label = "full" if full else "clone"
    home = root / "cli-proof" / ("full-home" if full else "cow--home")
    projects = home / ".claude/projects"
    projects.mkdir(parents=True)
    source = projects / "fixture.jsonl"
    source.write_text("".join(event(index) for index in range(24000)))
    (home / "config.json").write_text('{"version":1,"providers":[]}')
    env = {
        "PATH": "/usr/bin:/bin", "HOME": str(home), "CFFIXED_USER_HOME": str(home),
        "CLAUDE_CONFIG_DIR": str(home / ".claude"), "CODEXBAR_CONFIG": str(home / "config.json"),
        "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1", "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
        "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
        "DYLD_INSERT_LIBRARIES": str(root / "cli-write-observer.dylib"), "TZ": "UTC",
    }
    if full:
        env["PROOF_CLONE_ERRNO"] = str(errno.ENOTSUP)
    cache = home / "Library/Caches/CodexBar/cost-usage"

    def run(cycle):
        result = subprocess.run([str(binary), "cost", "--provider", "claude", "--format", "json"],
                                env=env, capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, f"{label} {cycle}: {result.stderr}"
        report = json.loads(result.stdout)
        match = re.search(r"CLI_WRITE_PROOF submitted=(\d+) clones=(\d+)", result.stderr)
        assert match, result.stderr
        (home / f"output-{cycle}.json").write_text(result.stdout)
        (home / f"output-{cycle}.log").write_text(result.stderr)
        assert not list(cache.glob(".claude-cache-*"))
        return [{k: v for k, v in item.items() if k != "updatedAt"} for item in report], int(match[1]), int(match[2])

    initial, _, _ = run(0)
    assert initial[0]["totals"]["totalTokens"] == 360000
    assert (cache / "claude-v6.json").exists()
    reports = []
    submitted = clones = 0
    for cycle in range(1, 13):
        with source.open("a") as stream:
            stream.write(event(24000 + cycle))
        report, writes, cloned = run(cycle)
        assert report[0]["totals"]["totalTokens"] == 360000 + 15 * cycle
        reports.append(report)
        submitted += writes
        clones += cloned
    cold, cold_bytes, _ = run("cold")
    assert cold == reports[-1] and cold_bytes == 0
    print(f"CLI_SUMMARY mode={label} rows=24000 appends=12 submitted={submitted} clones={clones} "
          f"coldSubmitted={cold_bytes} coldMatches=true", flush=True)
    results.append({"mode": label, "submitted": submitted, "clones": clones, "reports": reports})

    # Real full-write fallback after clone errors; then fail after partial private output.
    if not full:
        for cycle, failure in enumerate((errno.EXDEV, errno.ENOTSUP, errno.EROFS, errno.ENOSPC), start=13):
            with source.open("a") as stream:
                stream.write(event(24000 + cycle))
            env["PROOF_CLONE_ERRNO"] = str(failure)
            report, writes, cloned = run(f"clone-error-{failure}")
            assert report[0]["totals"]["totalTokens"] == 360000 + 15 * cycle
            assert writes > 0 and cloned == 0
            print(f"CLI_FALLBACK errno={errno.errorcode[failure]} clones=0 submitted={writes}", flush=True)
        del env["PROOF_CLONE_ERRNO"]
        before = {path.name: path.read_bytes() for path in cache.glob("claude-*.json")}
        with source.open("a") as stream:
            stream.write(event(24017))
        env["PROOF_FAIL_WRITES"] = "1"
        failed, writes, _ = run("partial-write-failure")
        assert writes == 64
        assert before == {path.name: path.read_bytes() for path in cache.glob("claude-*.json")}
        del env["PROOF_FAIL_WRITES"]
        recovered, _, _ = run("recovered")
        assert recovered == failed and recovered[0]["totals"]["totalTokens"] == 360255
        print("CLI_FAILURE partialBytes=64 targetUnchanged=true temporaryClean=true recovered=true", flush=True)

assert results[0]["reports"] == results[1]["reports"]
assert results[1]["clones"] > 0
assert results[1]["submitted"] * 2 < results[0]["submitted"]
print(f'CLI_RESULT reportsMatch=true reductionPercent={100 * (1 - results[1]["submitted"] / results[0]["submitted"]):.2f}')
(root / "cli-proof/results.json").write_text(json.dumps(results, indent=2))
