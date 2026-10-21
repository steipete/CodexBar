#!/usr/bin/env python3
"""Exercise the Codex cost smoke gate (#4672) with stub CLIs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check-linux-cli-codex-cost-smoke.sh')

# The stub fails unless it sees the reproducer's arguments and session file.
PREAMBLE = '''#!/bin/sh
[ "$*" = "cost --provider codex --json" ] || exit 64
[ -s "$CODEX_HOME/sessions/$(date +%Y/%m/%d)/rollout-test.jsonl" ] || exit 65
[ -d "$HOME" ] || exit 66
[ "$CODEXBAR_CONFIG" = "$(dirname "$HOME")/config.json" ] || exit 67
'''


class LinuxCLICodexCostSmokeTests(unittest.TestCase):
    def check(self, body):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'CodexBarCLI'
            binary.write_text(PREAMBLE + body)
            binary.chmod(0o755)
            return subprocess.run(['bash', str(SCRIPT), str(binary)],
                                  capture_output=True, text=True).returncode

    def test_accepts_json_output(self):
        self.assertEqual(self.check('printf \'{"provider":"codex","daily":[]}\\n\'\n'), 0)

    def test_rejects_segfault(self):
        self.assertNotEqual(self.check('kill -SEGV $$\n'), 0)

    def test_rejects_exit_139(self):
        self.assertNotEqual(self.check('printf "{}"\nexit 139\n'), 0)

    def test_rejects_invalid_json(self):
        self.assertNotEqual(self.check('printf "not json"\n'), 0)

    def test_rejects_empty_output(self):
        self.assertNotEqual(self.check('exit 0\n'), 0)


if __name__ == '__main__':
    unittest.main()
