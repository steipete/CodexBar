import base64
import importlib.util
import shutil
import os
import plistlib
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

    def test_appcast_generation_preserves_update_contract_with_markdown_notes(self):
        (self.root / 'CHANGELOG.md').write_text(
            '## 1.2.3 — 2026-01-01\n\n### Fixed\n\n- Fix wrapping (#4751). Thanks @octo!\n')
        (self.root / 'appcast.xml').write_text('<rss><channel><item><title>Older release</title></item></channel></rss>')
        directory = self.root / 'release-assets'
        directory.mkdir()
        archive = directory / release.CONFIG['app_archive'].format(version='1.2.3')
        archive.write_bytes(b'synthetic archive')
        app = self.root / 'Synthetic.app'
        (app / 'Contents').mkdir(parents=True)
        public_key = release.CONFIG['sparkle_public_key']
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'SUPublicEDKey': public_key}))
        old = Path.cwd()
        self.addCleanup(os.chdir, old)
        os.chdir(self.root)
        with patch.dict(os.environ, DRY_RUN='true', APP_BUNDLE=str(app),
                        SPARKLE_PRIVATE_KEY=base64.b64encode(bytes(32)).decode(),
                        SPARKLE_SIGN_UPDATE='synthetic-sign-update'), \
                patch.object(release, 'run', side_effect=[public_key, 'sparkle:edSignature="synthetic-signature"']), \
                patch.object(release.subprocess, 'run') as verify:
            release.appcast()
        items = release.ET.parse(directory / 'appcast.xml').findall('./channel/item')
        self.assertEqual(len(items), 2)
        item = items[0]
        self.assertEqual(items[1].findtext('title'), 'Older release')
        self.assertEqual(item.findtext(f'{{{release.SPARKLE}}}version'), '12')
        self.assertEqual(item.findtext(f'{{{release.SPARKLE}}}shortVersionString'), '1.2.3')
        self.assertEqual(item.findtext(f'{{{release.SPARKLE}}}minimumSystemVersion'), release.CONFIG['minimum_macos'])
        enclosure = item.find('enclosure')
        self.assertEqual(enclosure.attrib['length'], str(archive.stat().st_size))
        self.assertEqual(enclosure.attrib[f'{{{release.SPARKLE}}}edSignature'], 'synthetic-signature')
        self.assertEqual(enclosure.attrib['url'],
                         f'https://github.com/{release.CONFIG["repository"]}/releases/download/v1.2.3/{archive.name}')
        self.assertEqual(verify.call_args.args[0][-3:], ['--verify', str(archive.relative_to(self.root)), 'synthetic-signature'])
        description = item.find('description')
        self.assertEqual(description.attrib.get(f'{{{release.SPARKLE}}}format'), 'markdown')
        self.assertIn('## BlackBar 1.2.3\n\n### Fixed', description.text)
        self.assertIn('[#4751](https://github.com/steipete/CodexBar/issues/4751)', description.text)
        self.assertNotIn('<pre>', description.text)

    def test_appcast_description_uses_native_markdown_and_links_github_references(self):
        (self.root / 'CHANGELOG.md').write_text(
            '# Changelog\n\n## 1.2.3 - 2026-01-01\n\n'
            '### Highlights\n\n'
            'A paragraph with **bold text**, `inline code`, and '
            '[release docs](https://example.com/notes?a=1&b=2).\n'
            'Fixes (#4736, #4723). Thanks @Andy115951 and @octo-user! '
            'Keep `#12 @not-a-link` and mail@example.com as text.\n\n'
            '- Keep <literal> text & ampersands safe.\n'
            '- Long release notes stay in ordinary list items so Sparkle can wrap them.\n'
            '- Existing [#99](https://example.com/99) links are preserved.\n')

        item = release.ET.Element('item')
        description = release.add_appcast_description(item, '1.2.3')
        serialized = release.ET.tostring(item, encoding='unicode')
        parsed = release.ET.fromstring(serialized).find('description')

        self.assertEqual(description.attrib[f'{{{release.SPARKLE}}}format'], 'markdown')
        self.assertEqual(parsed.attrib[f'{{{release.SPARKLE}}}format'], 'markdown')
        self.assertIn('## BlackBar 1.2.3\n\n### Highlights', parsed.text)
        self.assertIn(
            '**bold text**, `inline code`, and [release docs](https://example.com/notes?a=1&b=2).',
            parsed.text)
        self.assertIn('[#4736](https://github.com/steipete/CodexBar/issues/4736)', parsed.text)
        self.assertIn('[@Andy115951](https://github.com/Andy115951)', parsed.text)
        self.assertIn('[@octo-user](https://github.com/octo-user)', parsed.text)
        self.assertIn('`#12 @not-a-link` and mail@example.com', parsed.text)
        self.assertIn('[#99](https://example.com/99)', parsed.text)
        self.assertIn('- Keep <literal> text & ampersands safe.', parsed.text)
        self.assertIn('- Long release notes stay in ordinary list items so Sparkle can wrap them.', parsed.text)

    def test_github_references_in_fenced_code_are_not_linked(self):
        markdown = 'Example:\n\n```text\n#12 @example\n```\n\nSee #13 and @octo.'
        self.assertEqual(
            release.link_github_references(markdown),
            'Example:\n\n```text\n#12 @example\n```\n\n'
            'See [#13](https://github.com/steipete/CodexBar/issues/13) and '
            '[@octo](https://github.com/octo).')

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
