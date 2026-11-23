"""Check that installer schemes belong to the same Stellae source commit."""
# SPDX-License-Identifier: GPL-3.0-only
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from zipfile import ZipFile

PACKAGE = Path(__file__).resolve().parents[3] / 'scripts/package'
sys.path.insert(0, str(PACKAGE))
from prepare_bundle import check_scheme_archive
sys.path.pop(0)


class SchemeSourceTests(unittest.TestCase):
    def archive(self, updates=None, changed=False, extra=False):
        data = b'-- fixed synthetic base input\n'
        manifest = {
            'format': 'stellae-scheme-package-v1', 'profile': 'stellae',
            'version': '2026.11.24', 'source_ref': 'a' * 40,
            'source_repository': 'https://github.com/unknownnumbers/rime-stellae',
            'source_prefix': 'schemes', 'personal_learning_included': False,
            'compiled_rime_dictionaries_included': False,
            'files': [{'path': 'UserProfile/rime.lua', 'bytes': len(data),
                       'sha256': hashlib.sha256(data).hexdigest()}],
        }
        manifest.update(updates or {})
        stream = io.BytesIO()
        with ZipFile(stream, 'w') as archive:
            archive.writestr('package-manifest.json', json.dumps(manifest))
            archive.writestr('UserProfile/rime.lua', b'changed' if changed else data)
            if extra:
                archive.writestr('unlisted.txt', 'unlisted')
        stream.seek(0)
        return ZipFile(stream)

    def check(self, archive):
        specification = {'schemes': {'sourceDirectory': 'schemes', 'profile': 'stellae',
                                     'version': '2026.11.24'}}
        return check_scheme_archive(archive, specification, 'a' * 40)

    def test_accepts_same_commit_scheme(self):
        with self.archive() as archive:
            self.assertEqual(self.check(archive)['source_ref'], 'a' * 40)

    def test_rejects_another_commit(self):
        with self.archive({'source_ref': 'b' * 40}) as archive:
            with self.assertRaisesRegex(ValueError, 'source commit'):
                self.check(archive)

    def test_rejects_another_repository(self):
        with self.archive({'source_repository': 'https://github.com/example/other'}) as archive:
            with self.assertRaisesRegex(ValueError, 'source commit'):
                self.check(archive)

    def test_rejects_changed_scheme_bytes(self):
        with self.archive(changed=True) as archive:
            with self.assertRaisesRegex(ValueError, 'member differs'):
                self.check(archive)

    def test_rejects_unlisted_archive_member(self):
        with self.archive(extra=True) as archive:
            with self.assertRaisesRegex(ValueError, 'members differ'):
                self.check(archive)


if __name__ == '__main__':
    unittest.main()
