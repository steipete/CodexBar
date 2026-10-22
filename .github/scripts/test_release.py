import base64
import importlib.util
import shutil
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.root_patch = patch.object(release, 'ROOT', self.root)
        self.root_patch.start()
        self.config_patch = patch.object(release, 'CONFIG', dict(release.CONFIG, app='BlackBar'))
        self.config_patch.start()
        (self.root / 'version.env').write_text('MARKETING_VERSION=1.2.3\nBUILD_NUMBER=12\n')
        (self.root / 'CHANGELOG.md').write_text('# Changelog\n\n## 1.2.3 - 2026-01-01\n\n- A real change.\n\n## 1.2.2 - 2025-12-01\n\n- Old.\n')
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.config_patch.stop)

    def test_minos_does_not_include_linker_tool_version(self):
        load = """Load command 10
          cmd LC_BUILD_VERSION
      cmdsize 32
     platform 1
        minos 14.0
          sdk 26.0
       ntools 1
         tool 3
      version 1221.4
Load command 11
          cmd LC_SOURCE_VERSION
      version 9999.1
"""
        self.assertEqual(release.deployment_targets(load), ['14.0'])

    def test_legacy_minimum_os_command(self):
        self.assertEqual(release.deployment_targets('Load command 1\n cmd LC_VERSION_MIN_MACOSX\n version 10.13\n sdk 14.4\n'), ['10.13'])

    def test_metadata_and_exact_notes(self):
        self.assertEqual(release.metadata(), ('1.2.3', '12'))
        self.assertEqual(release.notes('1.2.3'), '- A real change.\n')

    def test_undated_changelog_is_rejected(self):
        (self.root / 'CHANGELOG.md').write_text('## 1.2.3 - Unreleased\n\n- Change.\n')
        with self.assertRaises(AssertionError):
            release.notes('1.2.3')

    def test_duplicate_release_section_is_rejected(self):
        path = self.root / 'CHANGELOG.md'
        path.write_text(path.read_text() * 2)
        with self.assertRaises(AssertionError):
            release.notes('1.2.3')

    def test_invalid_version_is_rejected(self):
        (self.root / 'version.env').write_text('MARKETING_VERSION=1.2\nBUILD_NUMBER=1\n')
        with self.assertRaises(AssertionError):
            release.metadata()

    def test_unreleased_is_allowed_only_for_dry_runs(self):
        (self.root / 'CHANGELOG.md').write_text('## 1.2.3 — Unreleased\n\n')
        self.assertIn('Dry-run build', release.notes('1.2.3', dry=True))
        with self.assertRaises(AssertionError):
            release.notes('1.2.3')

    def test_release_notes_must_be_first_section(self):
        path = self.root / 'CHANGELOG.md'
        path.write_text('## 1.2.4 — Unreleased\n\n' + path.read_text())
        with self.assertRaises(AssertionError):
            release.notes('1.2.3')

    def test_future_date_is_rejected(self):
        (self.root / 'CHANGELOG.md').write_text('## 1.2.3 — 2999-01-01\n\n- Change.\n')
        with self.assertRaises(AssertionError):
            release.notes('1.2.3')

    def test_dry_run_does_not_check_or_reserve_release_availability(self):
        with patch.dict(os.environ, DRY_RUN='true'):
            with self.assertRaises(AssertionError):
                release.availability()

    def test_prerelease_metadata_and_channel(self):
        (self.root / 'version.env').write_text('MARKETING_VERSION=1.2.3-beta.2\nBUILD_NUMBER=12\n')
        self.assertEqual(release.metadata(), ('1.2.3-beta.2', '12'))
        self.assertEqual(release.sparkle_channel('1.2.3-beta.2'), 'beta')
        self.assertIsNone(release.sparkle_channel('1.2.3'))

    def test_publishing_prerelease_does_not_replace_latest_stable(self):
        for version in ['1.2.3', '1.2.3-beta.2']:
            with self.subTest(version=version):
                (self.root / 'version.env').write_text(f'MARKETING_VERSION={version}\nBUILD_NUMBER=12\n')
                (self.root / 'CHANGELOG.md').write_text(f'## {version} — 2026-01-01\n\n- Synthetic change.\n')
                feed = b'<rss><channel/></rss>'
                (self.root / 'appcast.xml').write_bytes(feed)
                directory = self.root / 'release-assets'
                if directory.exists(): shutil.rmtree(directory)
                directory.mkdir()
                for name in release.asset_names(version):
                    (directory / name).write_bytes(b'asset')
                    (directory / (name + '.sha256')).write_bytes(b'sidecar')
                (directory / 'appcast.xml').write_bytes(feed)
                (directory / 'RELEASE-NOTES.md').write_text(release.notes(version))
                (directory / 'SHA256SUMS').write_text(release.checksums(directory))
                def command(args, **kwargs):
                    if args[:3] == ['gh', 'release', 'download']:
                        target = self.root / args[-1]
                        for path in directory.iterdir(): shutil.copyfile(path, target / path.name)
                def git(*args):
                    return 'commit' if args[-1].endswith('^{commit}') else 'tag-object'
                response = {'object': {'type': 'tag', 'sha': 'tag-object'}, 'sha': 'feed-object', 'content': base64.b64encode(feed).decode()}
                old = Path.cwd()
                try:
                    os.chdir(self.root)
                    with patch.dict(os.environ, DRY_RUN='false', RELEASE_SHA='commit'), patch.object(release, 'require_ci'), patch.object(release, 'require_absent'), patch.object(release, 'api', return_value=response), patch.object(release, 'run', side_effect=git), patch.object(release.subprocess, 'run', side_effect=command) as commands:
                        release.publish()
                    calls = [c.args[0] for c in commands.call_args_list]
                    create = next(c for c in calls if c[:3] == ['gh', 'release', 'create'])
                    edit = next(c for c in calls if c[:3] == ['gh', 'release', 'edit'])
                    self.assertEqual('--prerelease' in create, '-' in version)
                    self.assertIn('--latest=false' if '-' in version else '--latest=true', edit)
                finally:
                    os.chdir(old)

    def test_dry_run_cannot_publish(self):
        with patch.dict(os.environ, DRY_RUN='true'), patch.object(release, 'api') as api:
            with self.assertRaises(AssertionError):
                release.publish()
            api.assert_not_called()

    def test_api_auth_failure_is_not_absence(self):
        with patch.object(release, 'api', side_effect=RuntimeError('HTTP 403')):
            with self.assertRaisesRegex(RuntimeError, 'HTTP 403'):
                release.require_absent('v1.2.3')

    def test_existing_draft_is_rejected(self):
        with patch.object(release, 'api', return_value=[{'tag_name': 'v1.2.3', 'draft': True}]):
            with self.assertRaisesRegex(AssertionError, 'already has'):
                release.require_absent('v1.2.3')

    def test_ci_must_be_exact_main_push_and_latest_attempt(self):
        sha = 'a' * 40
        old = dict(id=1, head_sha=sha, event='push', head_branch='main', run_number=1, run_attempt=1, status='completed', conclusion='success')
        rerun = dict(old, id=2, run_attempt=2, conclusion='failure')
        other = dict(old, head_sha='b' * 40)
        pr = dict(old, event='pull_request')
        for runs in [[other], [pr], [old, rerun]]:
            with self.subTest(runs=runs), patch.object(release, 'api', return_value={'workflow_runs': runs}):
                with self.assertRaises(AssertionError):
                    release.require_ci(sha)
        with patch.object(release, 'api', return_value={'workflow_runs': [old]}):
            self.assertEqual(release.require_ci(sha), 1)

    def test_checksum_covers_every_asset_but_itself(self):
        (self.root / 'app.zip').write_bytes(b'app')
        (self.root / 'SHA256SUMS').write_text('old')
        sums = release.checksums(self.root)
        self.assertIn('app.zip', sums)
        self.assertNotIn('SHA256SUMS', sums)
        (self.root / 'app.zip').write_bytes(b'tampered')
        self.assertNotEqual(sums, release.checksums(self.root))


if __name__ == '__main__':
    unittest.main()
