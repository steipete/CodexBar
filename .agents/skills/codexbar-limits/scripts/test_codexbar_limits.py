from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("codexbar-limits")

PLACEHOLDER_EMAIL = "<redacted:email>"
PLACEHOLDER_IDENTITY = "<redacted:identity>"
PLACEHOLDER_SECRET = "<redacted:secret>"

FAKE_CODEXBAR = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json
    import os
    import sys
    import time


    def scenario_key(argv):
        if argv == ["--version"]:
            return "VERSION"
        if argv[:2] == ["config", "providers"]:
            return "CONFIG_PROVIDERS"
        if argv[:2] == ["config", "validate"]:
            return "CONFIG_VALIDATE"
        if argv and argv[0] == "usage":
            if "--provider" in argv:
                provider = argv[argv.index("--provider") + 1]
                return "USAGE_" + provider.upper().replace("-", "_")
            return "USAGE_ENABLED"
        return "DEFAULT"


    argv = sys.argv[1:]
    log_path = os.environ.get("FAKE_CODEXBAR_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(argv) + "\\n")

    key = scenario_key(argv)
    delay = os.environ.get(f"FAKE_CODEXBAR_{key}_DELAY")
    if delay:
        time.sleep(float(delay))
    sys.stdout.write(os.environ.get(f"FAKE_CODEXBAR_{key}_STDOUT", ""))
    sys.stderr.write(os.environ.get(f"FAKE_CODEXBAR_{key}_STDERR", ""))
    raise SystemExit(int(os.environ.get(f"FAKE_CODEXBAR_{key}_EXIT", "0")))
    """
)


def sample_providers() -> list[dict[str, object]]:
    return [
        {"provider": "codex", "displayName": "Codex", "enabled": True, "defaultEnabled": True},
        {"provider": "openai", "displayName": "OpenAI", "enabled": False, "defaultEnabled": False},
    ]


def sample_usage(provider: str = "codex") -> list[dict[str, object]]:
    return [
        {
            "provider": provider,
            "source": "web",
            "usage": {
                "accountEmail": "alice@example.com",
                "accountOrganization": "ACME Org",
                "loginMethod": "oauth",
                "updatedAt": "2026-06-17T21:00:00Z",
                "primary": {
                    "windowMinutes": 60,
                    "usedPercent": 42,
                    "resetsAt": "2026-06-17T22:00:00Z",
                    "resetDescription": "resets in 1 hour",
                },
                "secondary": None,
                "tertiary": None,
                "extraRateWindows": [],
                "identity": {
                    "accountEmail": "alice@example.com",
                    "loginMethod": "oauth",
                    "providerID": "user-12345",
                },
            },
            "credits": {
                "remaining": 123,
                "updatedAt": "2026-06-17T21:05:00Z",
                "events": [],
            },
        }
    ]


def base_env(tmpdir: Path, *, with_fake_codexbar: bool = True) -> dict[str, str]:
    env = os.environ.copy()
    env.pop("CODEXBAR_LIMITS_CODEXBAR", None)
    env.pop("CODEXBAR_LIMITS_SKIP_DEFAULT_DISCOVERY", None)
    env["FAKE_CODEXBAR_VERSION_STDOUT"] = "CodexBar 1.2.3\n"
    env["FAKE_CODEXBAR_CONFIG_PROVIDERS_STDOUT"] = json.dumps(sample_providers())
    env["FAKE_CODEXBAR_CONFIG_VALIDATE_STDOUT"] = "[]"
    env["FAKE_CODEXBAR_USAGE_ENABLED_STDOUT"] = json.dumps(sample_usage())
    env["FAKE_CODEXBAR_USAGE_CODEX_STDOUT"] = json.dumps(sample_usage())
    env["FAKE_CODEXBAR_USAGE_ALL_STDOUT"] = json.dumps(sample_usage() + [{"provider": "openai", "source": "api", "usage": None, "credits": None}])

    if with_fake_codexbar:
        bin_dir = tmpdir / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        fake = bin_dir / "codexbar"
        fake.write_text(FAKE_CODEXBAR, encoding="utf-8")
        fake.chmod(0o755)
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
    else:
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["CODEXBAR_LIMITS_SKIP_DEFAULT_DISCOVERY"] = "1"

    return env


def install_fake_app_cli(tmpdir: Path, env: dict[str, str]) -> Path:
    app_cli = tmpdir / "CodexBar.app" / "Contents" / "Helpers" / "CodexBarCLI"
    app_cli.parent.mkdir(parents=True, exist_ok=True)
    app_cli.write_text(FAKE_CODEXBAR, encoding="utf-8")
    app_cli.chmod(0o755)
    env["CODEXBAR_LIMITS_CODEXBAR"] = str(app_cli)
    return app_cli


def run_helper(
    *args: str,
    env: dict[str, str],
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        cwd=str(cwd) if cwd else None,
    )


class CodexBarLimitsTests(unittest.TestCase):
    def test_help_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            result = run_helper("--help", env=env)
        self.assertEqual(result.returncode, 0)
        self.assertIn("doctor", result.stdout)
        self.assertIn("providers", result.stdout)
        self.assertIn("usage", result.stdout)
        self.assertIn("summary", result.stdout)

    def test_missing_codexbar_reports_machine_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp), with_fake_codexbar=False)
            result = run_helper("doctor", "--json", env=env)

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["codexbar_available"])
        self.assertEqual(payload["errors"][0]["classification"], "codexbar_missing")
        self.assertIn("brew install --cask codexbar", payload["errors"][0]["message"])

    def test_env_override_allows_app_bundle_cli_without_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = base_env(root, with_fake_codexbar=False)
            app_cli = install_fake_app_cli(root, env)
            result = run_helper("doctor", "--json", env=env)

        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["codexbar_available"])
        self.assertEqual(payload["codexbar"]["path"], str(app_cli))
        self.assertEqual(payload["codexbar"]["source"], "env_override")
        self.assertEqual(payload["doctor"]["codexbar_path"], str(app_cli))
        self.assertEqual(payload["doctor"]["codexbar_source"], "env_override")

    def test_home_relative_install_paths_are_redacted_in_default_json(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path.home()) as tmp:
            root = Path(tmp)
            env = base_env(root, with_fake_codexbar=False)
            app_cli = install_fake_app_cli(root, env)
            result = run_helper("doctor", "--json", env=env)

        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertNotIn(str(Path.home()), result.stdout)
        self.assertEqual(payload["codexbar"]["path"], "~/" + str(app_cli.relative_to(Path.home())))
        self.assertEqual(payload["doctor"]["codexbar_path"], "~/" + str(app_cli.relative_to(Path.home())))

    def test_providers_command_normalizes_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            result = run_helper("providers", "--json", env=env)

        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["codexbar_available"])
        self.assertEqual(
            payload["providers"],
            [
                {
                    "provider": "codex",
                    "display_name": "Codex",
                    "enabled": True,
                    "default_enabled": True,
                },
                {
                    "provider": "openai",
                    "display_name": "OpenAI",
                    "enabled": False,
                    "default_enabled": False,
                },
            ],
        )
        self.assertEqual(payload["usage"], [])
        self.assertEqual(payload["redacted"], {"identities": True, "secrets": True})

    def test_usage_enabled_redacts_identities_and_stderr(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["FAKE_CODEXBAR_USAGE_ENABLED_STDERR"] = json.dumps(
                {
                    "level": "error",
                    "label": "com.example.codex",
                    "message": "Bearer TOKEN_PLACEHOLDER for alice@example.com",
                }
            )
            result = run_helper("usage", "--enabled", "--json", env=env)

        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        usage_entry = payload["usage"][0]
        self.assertEqual(usage_entry["usage"]["account_email"], PLACEHOLDER_EMAIL)
        self.assertEqual(usage_entry["usage"]["account_organization"], PLACEHOLDER_IDENTITY)
        self.assertEqual(usage_entry["usage"]["identity"]["account_email"], PLACEHOLDER_EMAIL)
        self.assertEqual(usage_entry["usage"]["identity"]["provider_id"], PLACEHOLDER_IDENTITY)
        warning_message = payload["warnings"][0]["message"]
        self.assertIn(PLACEHOLDER_SECRET, warning_message)
        self.assertIn(PLACEHOLDER_EMAIL, warning_message)

    def test_usage_raw_includes_sanitized_upstream_payload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            result = run_helper("usage", "--provider", "codex", "--json", "--raw", env=env)

        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertIn("raw", payload)
        raw_entry = payload["raw"]["usage"][0]
        self.assertEqual(raw_entry["usage"]["accountEmail"], PLACEHOLDER_EMAIL)
        self.assertEqual(raw_entry["usage"]["identity"]["providerID"], PLACEHOLDER_IDENTITY)

    def test_include_identities_exposes_emails_but_masks_secret_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["FAKE_CODEXBAR_USAGE_CODEX_STDERR"] = "Authorization: Bearer sk-live-token-123 alice@example.com\n"
            result = run_helper("usage", "--provider", "codex", "--json", "--include-identities", env=env)

        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        usage_entry = payload["usage"][0]
        self.assertEqual(usage_entry["usage"]["account_email"], "alice@example.com")
        self.assertEqual(usage_entry["usage"]["identity"]["provider_id"], "user-12345")
        warning_message = payload["warnings"][0]["message"]
        self.assertIn(PLACEHOLDER_SECRET, warning_message)
        self.assertNotIn("sk-live-token-123", warning_message)
        self.assertNotIn("Bearer sk-live-token-123", warning_message)
        self.assertIn("alice@example.com", warning_message)
        self.assertEqual(payload["redacted"], {"identities": False, "secrets": True})

    def test_usage_all_partial_failure_keeps_payload_and_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["FAKE_CODEXBAR_USAGE_ALL_STDERR"] = "[openai stderr] access_token=YOUR_ACCESS_TOKEN_HERE\n"
            env["FAKE_CODEXBAR_USAGE_ALL_EXIT"] = "1"
            result = run_helper("usage", "--all", "--json", env=env)

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertGreaterEqual(len(payload["usage"]), 2)
        self.assertTrue(any(item["classification"] == "upstream_exit_nonzero" for item in payload["errors"]))
        joined_messages = "\n".join(item["message"] for item in payload["errors"] + payload["warnings"])
        self.assertIn(PLACEHOLDER_SECRET, joined_messages)

    def test_usage_preserves_provider_error_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["FAKE_CODEXBAR_USAGE_ALL_STDOUT"] = json.dumps(
                sample_usage()
                + [
                    {
                        "provider": "openai",
                        "source": "auto",
                        "error": {
                            "message": "No available fetch strategy for alice@example.com with token abc123",
                            "code": "no_strategy",
                        },
                    }
                ]
            )
            result = run_helper("usage", "--all", "--json", env=env)

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        error_entry = next(item for item in payload["usage"] if item["provider"] == "openai")
        self.assertEqual(error_entry["status"], "error")
        self.assertEqual(error_entry["error"]["code"], "no_strategy")
        self.assertIn(PLACEHOLDER_EMAIL, error_entry["error"]["message"])
        self.assertIn(PLACEHOLDER_SECRET, error_entry["error"]["message"])
        self.assertTrue(
            any(
                item["classification"] == "provider_usage_error" and item.get("provider") == "openai"
                for item in payload["errors"]
            )
        )

    def test_invalid_json_returns_machine_readable_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["FAKE_CODEXBAR_USAGE_ENABLED_STDOUT"] = "{not-json"
            result = run_helper("usage", "--enabled", "--json", env=env)

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertTrue(any(item["classification"] == "invalid_json" for item in payload["errors"]))

    def test_upstream_timeout_returns_json_error_instead_of_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["CODEXBAR_LIMITS_TIMEOUT"] = "1"
            env["FAKE_CODEXBAR_USAGE_ENABLED_DELAY"] = "2"
            result = run_helper("usage", "--enabled", "--json", env=env)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")
        payload = json.loads(result.stdout)
        self.assertTrue(any(item["classification"] == "upstream_timeout" for item in payload["errors"]))
        self.assertFalse(any(item["classification"] == "upstream_exit_nonzero" for item in payload["errors"]))

    def test_provider_inventory_timeout_returns_nonzero_for_enabled_usage(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = base_env(Path(tmp))
            env["CODEXBAR_LIMITS_TIMEOUT"] = "1"
            env["FAKE_CODEXBAR_CONFIG_PROVIDERS_DELAY"] = "2"
            result = run_helper("usage", "--enabled", "--json", env=env)

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertTrue(any(item["classification"] == "upstream_timeout" for item in payload["errors"]))

    def test_timeout_stops_process_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "child-survived"
            fake = root / "codexbar"
            fake.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import os
                    import subprocess
                    import sys
                    import time

                    if sys.argv[1:] == ["--version"]:
                        print("CodexBar 1.2.3")
                        raise SystemExit(0)
                    subprocess.Popen(
                        [
                            sys.executable,
                            "-c",
                            "import pathlib, time; time.sleep(2); pathlib.Path({str(marker)!r}).write_text('alive')",
                        ],
                        start_new_session=False,
                    )
                    time.sleep(3)
                    """
                ),
                encoding="utf-8",
            )
            fake.chmod(0o755)
            env = base_env(root, with_fake_codexbar=False)
            env["CODEXBAR_LIMITS_CODEXBAR"] = str(fake)
            env["CODEXBAR_LIMITS_TIMEOUT"] = "1"
            result = run_helper("usage", "--enabled", "--json", env=env)
            time.sleep(2.5)
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertTrue(any(item["classification"] == "upstream_timeout" for item in payload["errors"]))
            self.assertFalse(any(item["classification"] == "upstream_exit_nonzero" for item in payload["errors"]))
            self.assertFalse(marker.exists())

    def test_summary_runs_from_arbitrary_cwd_without_leaking_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = base_env(root)
            other = root / "elsewhere"
            other.mkdir()
            result = run_helper("summary", env=env, cwd=other)

        self.assertEqual(result.returncode, 0)
        self.assertIn("CodexBar limits summary", result.stdout)
        self.assertIn("Codex (codex)", result.stdout)
        self.assertNotIn("alice@example.com", result.stdout)


if __name__ == "__main__":
    unittest.main()
