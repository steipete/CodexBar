import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import os

sys.path.insert(0, str(Path(__file__).parent))
import homebrew

class HomebrewTests(unittest.TestCase):
    def test_cask_keeps_url_and_platform_contract(self):
        source = 'cask "app" do\n  version "1.0.0"\n  sha256 "' + 'a' * 64 + '"\n  url "https://example.com/#{version}.zip"\n  depends_on arch: :arm64\nend\n'
        changed = homebrew.rewrite_cask(source, '1.2.3', 'b' * 64)
        self.assertIn('version "1.2.3"', changed)
        self.assertIn('sha256 "' + 'b' * 64 + '"', changed)
        self.assertIn('depends_on arch: :arm64', changed)
        self.assertIn('https://example.com/#{version}.zip', changed)

    def test_unrecognized_cask_layout_fails_closed(self):
        with self.assertRaises(AssertionError):
            homebrew.rewrite_cask('version = "1.0.0"', '1.2.3', 'b' * 64)

    def test_formula_replaces_exact_platform_checksums(self):
        targets = ['macos-arm64', 'macos-x86_64', 'linux-aarch64', 'linux-x86_64']
        source = '  version "1.0.0"\n' + ''.join('  url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-' + t + '.tar.gz"\n  sha256 "' + 'a' * 64 + '"\n' for t in targets)
        digests = {t: str(i + 1) * 64 for i, t in enumerate(targets)}
        changed = homebrew.rewrite_formula(source, '1.2.3', digests)
        for digest in digests.values():
            self.assertIn(digest, changed)
        with self.assertRaises(AssertionError):
            homebrew.rewrite_formula(source.replace('macos-arm64', 'linux-x86_64'), '1.2.3', digests)

    def test_prerelease_cannot_write_the_stable_tap(self):
        with patch.dict(os.environ, DRY_RUN='false'), patch.object(homebrew, 'metadata', return_value=('1.2.3-beta.2', '12')), patch.object(homebrew, 'api') as api:
            with self.assertRaises(AssertionError): homebrew.main()
            api.assert_not_called()
