"""Exercise the server replacement boundary with fixed synthetic artifacts."""
# SPDX-License-Identifier: GPL-3.0-only
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPOSITORY = Path(__file__).resolve().parents[3]
MODULE_PATH = REPOSITORY / 'scripts/package/apply_server_overlays.py'
SPEC = importlib.util.spec_from_file_location('server_overlay_product', MODULE_PATH)
PRODUCT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCT)
SOURCE_REF = 'a' * 40
RUN_ID = 12345
CPP = b'// Fixed synthetic server source.\n'
HEADER = b'// Fixed synthetic server header.\n'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def image(machine, marker):
    raw = bytearray(96)
    raw[:2] = b'MZ'
    struct.pack_into('<I', raw, 0x3c, 64)
    raw[64:68] = b'PE\0\0'
    struct.pack_into('<H', raw, 68, machine)
    return bytes(raw) + marker.encode('ascii')


class ServerOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repository'
        self.stage = self.root / 'stage'
        self.overlays = self.root / 'overlays'
        self.base_files = {}
        self.old_bytes = {}
        paths = {
            '7z.dll': 0x14c, '7z.exe': 0x14c, 'curl.exe': 0x14c,
            'rime.dll': 0x8664, 'stellae.dll': 0x14c, 'stellae.ime': 0x14c,
            'StellaeDeployer.exe': 0x8664, 'StellaeServer.exe': 0x8664,
            'StellaeSetup.exe': 0x14c, 'stellaex64.dll': 0x8664,
            'stellaex64.ime': 0x8664, 'Win32/rime.dll': 0x14c,
            'Win32/StellaeDeployer.exe': 0x14c, 'Win32/StellaeServer.exe': 0x14c,
        }
        origins = []
        for name, architecture in paths.items():
            raw = image(architecture, 'original-' + name)
            path = self.stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
            self.old_bytes[name] = raw
            row = {'path': name, 'bytes': len(raw), 'sha256': digest(raw),
                   'source_ids': ['weasel', 'boost'],
                   'references': ['licenses/weasel.txt', 'licenses/boost.txt']}
            self.base_files[name] = row
            origins.append({'installed_path': name, 'source': 'frontendInstaller',
                            'sha256': digest(raw)})
        save(self.stage / 'base-package-license-index.json',
             {'files': list(self.base_files.values()),
              'sources': {'weasel': {'notices': ['licenses/weasel.txt']},
                          'boost': {'notices': ['licenses/boost.txt']}}})
        save(self.stage / 'bundle-provenance.json',
             {'bundleVersion': '2026.11.16', 'frontendVersion': '0.17.4.61052',
              'files': origins})
        save(self.stage / 'scheme-notices/package-license-index.json',
             {'files': [], 'sources': {}})
        specs = {}
        native = {'modeIconOverlay': {'candidateCppSha256': digest(CPP),
                                     'candidateHeaderSha256': digest(HEADER)},
                  'architectures': {}}
        complete_patch = digest(b'fixed synthetic complete patch')
        self.new_bytes = {}
        for arch, name, architecture in (
            ('x64', 'StellaeServer.exe', 0x8664),
            ('x86', 'Win32/StellaeServer.exe', 0x14c),
        ):
            root = self.overlays / arch
            root.mkdir(parents=True)
            raw = image(architecture, 'replacement-' + arch)
            self.new_bytes[name] = raw
            (root / 'StellaeServer.exe').write_bytes(raw)
            specs[arch] = {'installedPath': name, 'baseSha256': digest(self.old_bytes[name]),
                           'machine': architecture}
            engine = digest(('engine-' + arch).encode())
            native['architectures'][arch] = {'engineSha256': engine}
            archive = root / 'assembled-source.zip'
            with zipfile.ZipFile(archive, 'w') as zf:
                zf.writestr('source-archive-manifest.json', json.dumps({
                    'publicBuildCommit': SOURCE_REF, 'publicBuildRunId': RUN_ID}))
                zf.writestr('RimeWithWeasel/RimeWithWeasel.cpp', CPP)
                zf.writestr('include/RimeWithWeasel.h', HEADER)
            save(root / 'validation.json', {
                'passed': True, 'architecture': arch, 'commit': SOURCE_REF, 'run': str(RUN_ID),
                'sourceVersion': '0.17.4.61052', 'serverSha256': digest(raw),
                'candidateCppSha256': digest(CPP), 'candidateHeaderSha256': digest(HEADER),
                'completePatchSha256': complete_patch, 'engineUsedForImportLibrarySha256': engine,
                'notificationChecks': 47, 'shiftSnapshotChecks': 36, 'modeIconChecks': 49,
                'assembledSourceSha256': digest(archive.read_bytes()),
                'engineRebuilt': False, 'engineBundled': False, 'tsfBuilt': False,
                'clientsBuilt': False, 'profilesIncluded': False, 'installed': False,
            })
            self.checksums(arch)
        save(self.repo / 'installer/bundle-inputs.json', {
            'frontendVersion': '0.17.4.61052', 'serverOverlays': {'architectures': specs}})
        save(self.repo / 'native/notification-inputs.json', native)
        save(self.repo / 'native/source-manifest.json', {'patches': [{'sha256': complete_patch}]})

    def checksums(self, arch):
        root = self.overlays / arch
        rows = [digest(path.read_bytes()) + '  ' + path.relative_to(root).as_posix()
                for path in sorted(root.rglob('*'))
                if path.is_file() and path.name != 'SHA256SUMS.txt']
        (root / 'SHA256SUMS.txt').write_text('\n'.join(rows) + '\n', encoding='utf-8')

    def change_record(self, arch, **values):
        path = self.overlays / arch / 'validation.json'
        record = json.loads(path.read_text('utf-8'))
        record.update(values)
        save(path, record)
        self.checksums(arch)

    def apply(self):
        return PRODUCT.apply(self.stage, self.overlays, self.repo, SOURCE_REF, RUN_ID)

    def test_updates_only_two_servers_and_retains_provenance(self):
        result = self.apply()
        self.assertTrue(result['passed'])
        self.assertEqual((result['nativeImages'], result['unchangedNativeImages']), (14, 12))
        for name, raw in self.old_bytes.items():
            self.assertEqual((self.stage / name).read_bytes(), self.new_bytes.get(name, raw))
        origins = {item['installed_path']: item for item in result['rebuiltServers']}
        for arch, name in (('x64', 'StellaeServer.exe'), ('x86', 'Win32/StellaeServer.exe')):
            self.assertEqual(origins[name]['source'], 'rebuiltServer')
            self.assertEqual(origins[name]['original_sha256'], digest(self.old_bytes[name]))
            self.assertEqual(origins[name]['source_ref'], SOURCE_REF)
            self.assertEqual(origins[name]['corresponding_source'], 'server-' + arch + '-source.zip')

    def test_rejects_validly_hashed_stale_commit(self):
        self.change_record('x64', commit='b' * 40)
        with self.assertRaisesRegex(ValueError, 'source and run'):
            self.apply()

    def test_rejects_validly_hashed_swapped_architecture(self):
        raw = image(0x14c, 'incorrect-x64-machine')
        (self.overlays / 'x64/StellaeServer.exe').write_bytes(raw)
        self.change_record('x64', serverSha256=digest(raw))
        with self.assertRaisesRegex(ValueError, 'source and run'):
            self.apply()

    def test_rejects_truncated_executable_even_with_matching_hashes(self):
        raw = b'MZshort'
        (self.overlays / 'x64/StellaeServer.exe').write_bytes(raw)
        self.change_record('x64', serverSha256=digest(raw))
        with self.assertRaisesRegex(ValueError, 'executable header'):
            self.apply()

    def test_rejects_an_extra_native_image(self):
        (self.stage / 'unexpected.exe').write_bytes(image(0x14c, 'extra'))
        with self.assertRaisesRegex(ValueError, 'image set'):
            self.apply()

    def test_rejects_a_modified_retained_engine(self):
        (self.stage / 'rime.dll').write_bytes(image(0x8664, 'modified-engine'))
        with self.assertRaisesRegex(ValueError, 'original native image differs'):
            self.apply()

    def test_rejects_unverified_artifact_bytes(self):
        (self.overlays / 'x64/StellaeServer.exe').write_bytes(image(0x8664, 'unhashed'))
        with self.assertRaisesRegex(ValueError, 'artifact bytes differ'):
            self.apply()

    def test_rejects_source_archive_with_changed_cpp(self):
        root = self.overlays / 'x64'
        archive = root / 'assembled-source.zip'
        with zipfile.ZipFile(archive, 'w') as zf:
            zf.writestr('source-archive-manifest.json', json.dumps({
                'publicBuildCommit': SOURCE_REF, 'publicBuildRunId': RUN_ID}))
            zf.writestr('RimeWithWeasel/RimeWithWeasel.cpp', b'changed source')
            zf.writestr('include/RimeWithWeasel.h', HEADER)
        self.change_record('x64', assembledSourceSha256=digest(archive.read_bytes()))
        with self.assertRaisesRegex(ValueError, 'rebuilt server source'):
            self.apply()

    def test_rejects_bundled_engine_scope(self):
        self.change_record('x64', engineBundled=True)
        with self.assertRaisesRegex(ValueError, 'exceeded its scope'):
            self.apply()

    def test_bundle_recipe_installs_and_removes_indexed_server_report(self):
        self.apply()
        result = subprocess.run([sys.executable, str(REPOSITORY / 'scripts/package/index_bundle.py'),
                                 '--stage', str(self.stage), '--ref', SOURCE_REF],
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.stage / 'package-manifest.json').read_text('utf-8'))
        report = 'server-overlay-verification.json'
        row = next(item for item in manifest['files'] if item['path'] == report)
        self.assertEqual(row['installed_path'], report)
        self.assertEqual(row['sha256'], digest((self.stage / report).read_bytes()))
        recipe = (REPOSITORY / 'installer/install.nsi').read_text('utf-8-sig')
        first = recipe.index('  SetOutPath "$INSTDIR\\scheme-notices"')
        last = recipe.index('  SetOutPath "$PLUGINSDIR\\shared-payload"', first)
        guard = recipe.rfind('!ifndef STELLAE_BUNDLE', 0, first)
        self.assertGreaterEqual(guard, 0)
        self.assertLess(recipe.index('!else', guard), first)
        self.assertGreater(recipe.index('!endif', guard), last)
        destination = None
        installed = {}
        for line in recipe[first:last].splitlines():
            out = re.fullmatch(r'\s*SetOutPath "([^"]+)"\s*', line)
            source = re.fullmatch(r'\s*File "([^"]+)"\s*', line)
            if out:
                destination = out.group(1)
            elif source:
                installed[source.group(1)] = destination
        self.assertEqual(installed.get(report), '$INSTDIR',
                         'The indexed report must be embedded at its declared root path.')
        uninstall = recipe.split('Section "Uninstall"', 1)[1].split('SectionEnd', 1)[0]
        self.assertRegex(uninstall, r'(?m)^\s*Delete\s+"\$INSTDIR\\\*\.\*"\s*$',
                         'The owned root report must be covered by normal uninstall cleanup.')

    def test_index_retains_exact_inherited_licenses(self):
        self.apply()
        result = subprocess.run([sys.executable, str(REPOSITORY / 'scripts/package/index_bundle.py'),
                                 '--stage', str(self.stage), '--ref', SOURCE_REF],
                                capture_output=True, text=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        index = json.loads((self.stage / 'package-license-index.json').read_text('utf-8'))
        rows = {row['installed_path']: row for row in index['files']}
        for arch, name in (('x64', 'StellaeServer.exe'), ('x86', 'Win32/StellaeServer.exe')):
            row = rows[name]
            self.assertEqual(row['sha256'], digest(self.new_bytes[name]))
            self.assertEqual(row['original_sha256'], digest(self.old_bytes[name]))
            self.assertEqual(row['license_record'], self.base_files[name])
            self.assertTrue({'project-code', 'weasel', 'boost'}.issubset(row['source_ids']))
            self.assertEqual(row['generated_license'], 'GPL-3.0-only')
            self.assertEqual(row['corresponding_source'], 'server-' + arch + '-source.zip')
            self.assertEqual(row['rebuild_source_ref'], SOURCE_REF)
            self.assertEqual(row['rebuild_run_id'], RUN_ID)


if __name__ == '__main__':
    unittest.main()
