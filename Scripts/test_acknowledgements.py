#!/usr/bin/env python3
"""Offline regressions for notice coverage and packaging."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('acknowledgements', Path(__file__).with_name('acknowledgements.py'))
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class AcknowledgementsTests(unittest.TestCase):
    def setUp(self):
        self.entries = json.loads((notices.ROOT / notices.RESOURCE).read_text())

    def test_resolved_packages_and_vendored_notices_are_covered(self):
        notices.check(notices.ROOT, self.entries)
        rendered = notices.render(self.entries)
        for expected in ['Commander', 'KeyboardShortcuts', 'Sparkle', 'SweetCookieKit', 'swift-log',
                         'swift-crypto', 'swift-asn1', 'Vortex', 'QuickJS', 'Zstandard', 'UNICODE LICENSE V3',
                         'BoringSSL', 'XKCP', 'Brian Gladman', 'Sucrase', '@jridgewell/gen-mapping',
                         '@jridgewell/resolve-uri', '@jridgewell/sourcemap-codec',
                         '@jridgewell/trace-mapping', 'lines-and-columns', 'ts-interface-checker']:
            self.assertIn(expected, rendered)

    def test_dependency_addition_or_pin_change_requires_refresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for lock in notices.LOCKS:
                path = root / lock
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((notices.ROOT / lock).read_bytes())
            pin_file = root / notices.LOCKS[0]
            data = json.loads(pin_file.read_text())
            data['pins'].append({'identity': 'new-dependency', 'location': 'https://example.com/new',
                                 'state': {'revision': 'a' * 40}})
            pin_file.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'Update PACKAGES'):
                notices.check(root, self.entries)
            data['pins'].pop()
            data['pins'][0]['state']['revision'] = 'b' * 40
            pin_file.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'pins disagree'):
                notices.check(root, self.entries)

    def test_missing_or_modified_notice_is_rejected(self):
        entries = copy.deepcopy(self.entries)
        entries[0]['sources'][0]['text'] += 'edited'
        with self.assertRaisesRegex(ValueError, 'notice changed'):
            notices.check(notices.ROOT, entries)
        entries = [item for item in self.entries if item['name'] != 'XKCP']
        with self.assertRaisesRegex(ValueError, 'missing'):
            notices.check(notices.ROOT, entries)

    def test_release_archives_export_the_common_resource(self):
        workflow = (notices.ROOT / '.github/workflows/release-cli.yml').read_text()
        self.assertIn('Scripts/acknowledgements.py --text-output "$OUT_DIR/THIRD_PARTY_NOTICES"', workflow)
        self.assertIn('CodexBarCLI codexbar VERSION THIRD_PARTY_NOTICES CodexBar_CodexBarCore.bundle', workflow)


if __name__ == '__main__':
    unittest.main()
