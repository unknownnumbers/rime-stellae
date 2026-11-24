"""Exercise source staging for the x64 backend and compatibility clients."""
# SPDX-License-Identifier: GPL-3.0-only
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts/package'))
from apply_frontend_overlays import PRODUCTS, ENGINES
from bundle_architecture import LEGACY_X86_BACKEND
sys.path.pop(0)
REF = 'a' * 40


def record(path, raw):
    return {'path': path, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def save(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)


class BundleArchitectureStagingTests(unittest.TestCase):
    def test_stages_only_x64_backend_and_applies_user_defaults_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base, official, stage = [root / name for name in ('base', 'official', 'stage')]
            files = {name: ('original:' + name).encode()
                     for names in PRODUCTS.values() for name in names}
            files.update({name: ('original:' + name).encode() for _, name in ENGINES.values()})
            files.update({name: name.encode() for name in ('7z.exe', '7z.dll', 'curl.exe', 'StellaeSetup.exe')})
            files.update({'data/default.yaml': b'config_version: synthetic\n',
                          'data/weasel.yaml': b'config_version: synthetic\n'})
            base_records = [record(name, raw) for name, raw in files.items()]
            for name, raw in files.items():
                save(base / name, raw)
            for name in ('package-manifest.json', 'package-license-index.json'):
                save(base / name, json.dumps({'files': base_records}).encode())
            for name in ('pinyin.yaml', 'stroke.schema.yaml', 'stroke.dict.yaml'):
                save(official / 'data' / name, b'# fixed synthetic dependency\n')
            profile = {
                'default.yaml': (b'config_version: synthetic\n\n__patch:\n'
                                 b'  - stellae/defaults:/patch\n  - default.custom:/patch?\n'),
                'default.custom.yaml': b'patch:\n',
                'weasel.custom.yaml': b'patch:\n  style/font_point: 12\n',
            }
            source_manifest = {'source_files': [record(name, raw) for name, raw in profile.items()],
                               'generated_files': []}
            profile['config-source-manifest.json'] = json.dumps(source_manifest).encode()
            members = {'UserProfile/' + name: raw for name, raw in profile.items()}
            members['source-config-manifest.json'] = json.dumps(source_manifest).encode()
            members['package-license-index.json'] = b'{"files": [], "sources": {}}'
            manifest = {
                'format': 'stellae-scheme-package-v1', 'source_ref': REF,
                'source_repository': 'https://github.com/unknownnumbers/rime-stellae',
                'source_prefix': 'schemes', 'version': 'synthetic', 'profile': 'stellae',
                'personal_learning_included': False, 'compiled_rime_dictionaries_included': False,
                'files': [record(name, raw) for name, raw in members.items()],
            }
            archive = root / 'schemes.zip'
            with ZipFile(archive, 'w') as output:
                for name, raw in members.items():
                    output.writestr(name, raw)
                output.writestr('package-manifest.json', json.dumps(manifest))
            inputs = {'bundleVersion': 'synthetic', 'frontendVersion': '0.17.4.61052',
                      'schemes': {'sourceDirectory': 'schemes', 'profile': 'stellae', 'version': 'synthetic'},
                      'nativeFrontend': {'clientOnlyArchitectures': ['x86']},
                      'nativeEngines': {'x64': 'engine-n01'}}
            input_path = root / 'inputs.json'
            save(input_path, json.dumps(inputs).encode())
            subprocess.run([sys.executable, str(REPO / 'scripts/package/prepare_bundle.py'),
                            '--repository', str(REPO), '--base', str(base), '--official', str(official),
                            '--schemes', str(archive), '--source-ref', REF, '--inputs', str(input_path),
                            '--stage', str(stage)], check=True, capture_output=True, text=True)
            for name in LEGACY_X86_BACKEND:
                self.assertFalse((stage / name).exists(), name)
            for name in ('stellae.dll', 'stellae.ime', 'StellaeServer.exe', 'rime.dll'):
                self.assertEqual((stage / name).read_bytes(), files[name])
            default = (stage / 'shared-payload/data/default.yaml').read_text()
            self.assertEqual(default.count('__patch:'), 1)
            self.assertEqual(default.count('default.custom:/patch?'), 1)
            self.assertTrue(default.endswith('  - default.custom:/patch?\n'))
            provenance = json.loads((stage / 'bundle-provenance.json').read_text())
            self.assertEqual({row['installed_path'] for row in provenance['excludedNativeImages']},
                             set(LEGACY_X86_BACKEND))
            self.assertEqual((stage / 'bundle_architecture.nsh').read_text().count('!define STELLAE_X64_BACKEND'), 1)
            self.assertTrue((stage / 'shared-payload/migrations/source-layout.json').is_file())


if __name__ == '__main__':
    unittest.main()
