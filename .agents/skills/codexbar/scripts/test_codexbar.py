from __future__ import annotations

import json
import os
import runpy
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("codexbar")
MODULE = runpy.run_path(str(SCRIPT), run_name="codexbar_skill")
MAX_CAPTURE_BYTES = MODULE["MAX_CAPTURE_BYTES"]
run_process = MODULE["run_process"]

FAKE = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json
    import os
    import subprocess
    import sys
    import time

    argv = sys.argv[1:]
    log = os.environ.get("FAKE_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(argv) + "\\n")

    if argv == ["--version"]:
        key = "VERSION"
    elif argv[:2] == ["config", "validate"]:
        key = "VALIDATE"
    elif argv[:2] == ["config", "providers"]:
        key = "PROVIDERS"
    elif argv and argv[0] == "usage":
        key = "USAGE"
    else:
        key = "OTHER"

    if os.environ.get("FAKE_SPAWN_CHILD") == "1":
        marker = os.environ["FAKE_MARKER"]
        subprocess.Popen([
            sys.executable,
            "-c",
            f"import pathlib,time; time.sleep(2); pathlib.Path({marker!r}).write_text('alive')",
        ])
        time.sleep(5)

    delay = os.environ.get(f"FAKE_{key}_DELAY")
    if delay:
        time.sleep(float(delay))
    stdout = os.environ.get(f"FAKE_{key}_STDOUT", "")
    stderr = os.environ.get(f"FAKE_{key}_STDERR", "")
    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    raise SystemExit(int(os.environ.get(f"FAKE_{key}_EXIT", "0")))
    """
)


def make_env(root: Path, *, install: bool = True) -> tuple[dict[str, str], Path]:
    binary = root / "CodexBar.app" / "Contents" / "Helpers" / "CodexBarCLI"
    binary.parent.mkdir(parents=True)
    binary.write_text(FAKE, encoding="utf-8")
    binary.chmod(0o755)
    env = os.environ.copy()
    env["CODEXBAR_SKIP_DISCOVERY"] = "1"
    env["CODEXBAR_TIMEOUT"] = "3"
    env["FAKE_LOG"] = str(root / "argv.log")
    env["FAKE_VERSION_STDOUT"] = "CodexBar 1.2.3\n"
    env["FAKE_VALIDATE_STDOUT"] = "[]"
    env["FAKE_PROVIDERS_STDOUT"] = json.dumps(
        [{"provider": "codex", "displayName": "Codex", "enabled": True}]
    )
    env["FAKE_USAGE_STDOUT"] = json.dumps(
        [
            {
                "provider": "codex",
                "source": "oauth",
                "usage": {
                    "accountEmail": "alice@example.com",
                    "accountOrganization": "Example Org",
                    "identity": {"providerID": "codex", "accountID": "acct-123"},
                    "primary": {"usedPercent": 42, "windowMinutes": 300},
                },
            }
        ]
    )
    if install:
        env["CODEXBAR_BIN"] = str(binary)
    else:
        env.pop("CODEXBAR_BIN", None)
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env, binary


def helper(*args: str, env: dict[str, str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        cwd=cwd,
    )


class CodexBarSkillTests(unittest.TestCase):
    def test_help_is_small_and_read_only(self) -> None:
        result = helper("--help", env=os.environ.copy())
        self.assertEqual(result.returncode, 0)
        self.assertIn("CodexBar read. JSON out. No writes.", result.stdout)
        self.assertNotIn("enable", result.stdout)
        self.assertNotIn("set-api-key", result.stdout)

    def test_missing_binary_is_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env, _ = make_env(Path(tmp), install=False)
            result = helper("doctor", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["error"]["kind"], "missing")

    def test_doctor_reports_version_and_raw_validation_shape(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as tmp:
            env, binary = make_env(Path(tmp))
            result = helper("doctor", env=env)
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["version"], "CodexBar 1.2.3")
        self.assertEqual(payload["configIssues"], [])
        self.assertEqual(payload["binary"]["path"], "~" + str(binary)[len(str(Path.home())) :])

    def test_providers_passes_upstream_json_without_second_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env, _ = make_env(Path(tmp))
            result = helper("providers", env=env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            [{"provider": "codex", "displayName": "Codex", "enabled": True}],
        )

    def test_usage_defaults_to_enabled_and_runs_from_any_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env, _ = make_env(root)
            elsewhere = root / "elsewhere"
            elsewhere.mkdir()
            result = helper("usage", env=env, cwd=elsewhere)
            calls = [json.loads(line) for line in (root / "argv.log").read_text().splitlines()]
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, [["usage", "--format", "json", "--json-only"]])

    def test_usage_scope_maps_to_upstream_cli(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env, _ = make_env(root)
            self.assertEqual(helper("usage", "--all", env=env).returncode, 0)
            self.assertEqual(helper("usage", "--provider", "zai", env=env).returncode, 0)
            calls = [json.loads(line) for line in (root / "argv.log").read_text().splitlines()]
        self.assertEqual(calls[0][-2:], ["--provider", "all"])
        self.assertEqual(calls[1][-2:], ["--provider", "zai"])

    def test_usage_hides_identity_but_preserves_provider_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env, _ = make_env(Path(tmp))
            env["FAKE_USAGE_STDERR"] = (
                "Authorization: Bearer secret-token alice@example.com; token sk-live-prose-secret\n"
            )
            result = helper("usage", env=env)
        payload = json.loads(result.stdout)[0]
        self.assertEqual(payload["provider"], "codex")
        self.assertEqual(payload["usage"]["identity"]["providerID"], "codex")
        self.assertEqual(payload["usage"]["accountEmail"], "<redacted:email>")
        self.assertEqual(payload["usage"]["accountOrganization"], "<redacted:identity>")
        self.assertEqual(payload["usage"]["identity"]["accountID"], "<redacted:identity>")
        self.assertNotIn("secret-token", result.stderr)
        self.assertNotIn("sk-live-prose-secret", result.stderr)
        self.assertIn("<redacted:secret>", result.stderr)

    def test_include_identities_never_exposes_secret_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env, _ = make_env(Path(tmp))
            payload = json.loads(env["FAKE_USAGE_STDOUT"])
            payload[0]["usage"]["apiKey"] = "super-secret"
            env["FAKE_USAGE_STDOUT"] = json.dumps(payload)
            result = helper("usage", "--include-identities", env=env)
        usage = json.loads(result.stdout)[0]["usage"]
        self.assertEqual(usage["accountEmail"], "alice@example.com")
        self.assertEqual(usage["apiKey"], "<redacted:secret>")

    def test_each_stream_is_capped_while_fully_drained(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            writer = root / "writer"
            writer.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "sys.stdout.buffer.write(b'o' * 2000000)\n"
                "sys.stderr.buffer.write(b'e' * 2000000)\n",
                encoding="utf-8",
            )
            writer.chmod(0o755)
            result = run_process([str(writer)])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), MAX_CAPTURE_BYTES)
        self.assertEqual(len(result.stderr), MAX_CAPTURE_BYTES)

    def test_timeout_kills_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env, _ = make_env(root)
            marker = root / "child-survived"
            env["CODEXBAR_TIMEOUT"] = "1"
            env["FAKE_SPAWN_CHILD"] = "1"
            env["FAKE_MARKER"] = str(marker)
            result = helper("usage", env=env)
            time.sleep(2.2)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(json.loads(result.stdout)["error"]["kind"], "timeout")
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
