#!/usr/bin/env python3
"""Exercise the glibc link gate without depending on host ELF tooling."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check-linux-cli-linkage.sh')


class LinuxCLILinkageTests(unittest.TestCase):
    def check(self, output, code=0):
        with tempfile.TemporaryDirectory() as directory:
            readelf = Path(directory) / 'readelf'
            readelf.write_text('#!/bin/sh\nprintf "%s\\n" "$READELF_OUTPUT"\nexit "$READELF_CODE"\n')
            readelf.chmod(0o755)
            environment = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                               READELF_OUTPUT=output, READELF_CODE=str(code))
            return subprocess.run(['bash', str(SCRIPT), 'fixture'], env=environment,
                                  capture_output=True, text=True).returncode

    def test_accepts_non_xml_dependencies(self):
        self.assertEqual(self.check('0x1 (NEEDED) Shared library: [libc.so.6]'), 0)

    def test_rejects_xml_sonames(self):
        for soname in ['libxml2.so.2', 'libxml2.so.16']:
            self.assertNotEqual(self.check(f'0x1 (NEEDED) Shared library: [{soname}]'), 0)

    def test_rejects_empty_dynamic_table(self):
        self.assertNotEqual(self.check('There is no dynamic section in this file.'), 0)

    def test_rejects_failed_inspection_even_with_valid_output(self):
        self.assertNotEqual(self.check('0x1 (NEEDED) Shared library: [libc.so.6]', code=1), 0)


if __name__ == '__main__':
    unittest.main()
