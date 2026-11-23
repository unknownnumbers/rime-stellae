"""Validate isolated runtime integration with synthetic native artifacts."""
# SPDX-License-Identifier: GPL-3.0-only
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from zipfile import ZipFile


PACKAGE = Path(__file__).resolve().parents[3] / 'scripts/package'
sys.path.insert(0, str(PACKAGE))
import apply_frontend_overlays as overlay
sys.path.pop(0)

REF = 'a' * 40
NATIVE_SOURCE = 'src/main.cc'
TEXT = b'// synthetic engine source\n'


def image(machine, marker):
    data = bytearray(96)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<H', data, 68, machine)
    return bytes(data) + marker.encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def save(path, data):
    write(path, json.dumps(data).encode())


class RuntimeEngineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.stage = self.root / 'stage'
        self.engines = self.root / 'engine-builds'
        self.sources = self.root / 'engine-sources'
        self.products = self.root / 'frontend-builds'
        self.native = self.root / 'native/source-manifest.json'
        native = {
            'sources': {'librime': {'commit': 'c' * 40}},
            'enginePlugins': [], 'patches': [],
            'variants': {variant: {'rootSource': 'librime', 'components': []}
                         for variant, _ in overlay.ENGINES.values()},
        }
        save(self.native, native)
        write(self.root / 'LICENSE', b'Project license\n')
        write(self.root / 'licenses/engine-notice.txt', b'Upstream engine notice\n')
        bundle = {
            'bundleVersion': '2026.11.20', 'frontendVersion': '0.17.4.61052',
            'nativeFrontend': {'sourceFiles': {NATIVE_SOURCE: sha(TEXT)}},
            'nativeEngines': {arch: variant for arch, (variant, _) in overlay.ENGINES.items()},
        }
        save(self.stage / 'bundle-inputs.json', bundle)
        paths = {name: arch for arch, names in overlay.PRODUCTS.items() for name in names}
        paths.update({name: arch for arch, (_, name) in overlay.ENGINES.items()})
        paths.update({name: 'x86' for name in (
            '7z.dll', '7z.exe', 'curl.exe', 'StellaeSetup.exe',
        )})
        base, origins = [], []
        for name, arch in paths.items():
            raw = image(overlay.MACHINES[arch], 'original-' + name)
            write(self.stage / name, raw)
            base.append({'path': name, 'bytes': len(raw), 'sha256': sha(raw), 'source_ids': ['original']})
            origins.append({'installed_path': name, 'source': 'frontendInstaller', 'sha256': sha(raw)})
        save(self.stage / 'base-package-license-index.json', {'files': base, 'sources': {'original': {}}})
        save(self.stage / 'bundle-provenance.json', bundle | {'inputs': bundle, 'files': origins})
        save(self.stage / 'scheme-notices/package-license-index.json', {'files': [], 'sources': {}})
        snapshot = self.stage / 'scheme-notices/archive-profile-manifest.json'
        save(snapshot, {})
        save(self.stage / 'shared-payload/data/config-source-manifest.json', {
            'source_files': [], 'generated_files': [], 'archive_provenance': {
                'original_manifest': snapshot.relative_to(self.stage).as_posix(),
                'original_manifest_sha256': overlay.digest(snapshot),
            },
        })
        for arch, (variant, _) in overlay.ENGINES.items():
            self.write_frontend(arch)
            self.write_engine(arch, variant)

    def write_frontend(self, arch):
        root = self.products / arch
        root.mkdir(parents=True)
        archive = root / 'candidate-source.zip'
        with ZipFile(archive, 'w') as out:
            out.writestr(NATIVE_SOURCE, TEXT)
        products = []
        for name in overlay.PRODUCTS[arch]:
            raw = image(overlay.MACHINES[arch], 'frontend-' + name)
            write(root / Path(name).name, raw)
            products.append({
                'installedRelativePath': name, 'version': '0.17.4.61052', 'machine': overlay.MACHINES[arch],
                'bytes': len(raw), 'sha256': sha(raw),
            })
        save(root / 'build-result.json', {
            'passed': True, 'architecture': arch, 'sourceVersion': '0.17.4.61052', 'symbolsBundled': False,
            'engineBundled': False, 'engineRebuilt': False, 'optInNumericTraceCompiled': False,
            'candidateSourceArchiveSha256': overlay.digest(archive), 'products': products,
        })

    def write_engine(self, arch, variant):
        root = self.engines / arch
        raw = image(overlay.MACHINES[arch], 'fresh-engine-' + arch)
        write(root / 'dist/lib/rime.dll', raw)
        for name in ('LICENSE', 'licenses/engine-notice.txt'):
            write(root / name, (self.root / name).read_bytes())
        sources = [{'path': '.', 'source': 'librime', 'commit': 'c' * 40}]
        assembly = root / 'native-source-assembly.json'
        save(assembly, {
            'schema': 'stellae-native-assembly/1', 'variant': variant, 'sourceAssemblyPassed': True,
            'sources': sources, 'patches': [],
        })
        content = {NATIVE_SOURCE: TEXT, assembly.name: assembly.read_bytes()}
        archive = root / 'assembled-source.zip'
        with ZipFile(archive, 'w') as out:
            for name, data in content.items():
                out.writestr(name, data)
            out.writestr('source-archive-manifest.json', json.dumps({
                'schema': 'stellae-assembled-source/1', 'variant': variant, 'capturedBeforeCompilation': True,
                'sources': sources, 'gitMetadataIncluded': False, 'excludedPrebuiltFiles': [],
                'files': [{'path': name, 'bytes': len(data), 'sha256': sha(data)} for name, data in content.items()],
                'publicBuildCommit': 'b' * 40, 'publicBuildRunId': '918375',
            }))
        save(root / 'build-result.json', {
            'schema': 'stellae-native-build/1', 'variant': variant, 'architecture': arch,
            'manifestSha256': overlay.digest(self.native), 'compilationPassed': True, 'upstreamCTestPassed': True,
            'peMetadataVerified': True, 'symbolsBundled': False, 'preeditHelperChecks': 34, 'sha256': sha(raw),
            'assembledSourceSha256': overlay.digest(archive), 'assembledSourceFiles': len(content),
        })

    def apply(self):
        return overlay.apply(self.stage, self.products, self.products, REF, self.engines, self.native, self.sources)

    def run_package_script(self, name, *args):
        return subprocess.run([sys.executable, str(PACKAGE / name), *map(str, args)],
                              check=True, capture_output=True, text=True)

    def test_pins_sources_preserves_notices_and_verifies_both_extracted_engines(self):
        proof = self.apply()
        self.assertEqual((len(proof['rebuiltImages']), len(proof['rebuiltRuntimeEngines'])), (8, 2))
        self.assertEqual(proof['unchangedNativeImages'], 4)
        self.assertFalse(proof['runtimeEnginesPreserved'])
        for row in proof['rebuiltRuntimeEngines']:
            with ZipFile(self.sources / row['corresponding_source']) as source:
                self.assertEqual(source.read(NATIVE_SOURCE), TEXT)
                self.assertNotIn('publicBuildRunId', json.loads(source.read('source-archive-manifest.json')))
                self.assertNotIn('publicBuildCommit', json.loads(source.read('source-archive-manifest.json')))
        self.run_package_script('index_bundle.py', '--stage', self.stage, '--ref', REF)
        extracted = self.root / 'extracted'
        shutil.copytree(self.stage, extracted)
        (extracted / 'Win32/rime.dll').rename(extracted / 'rime_1.dll')
        report = self.root / 'report.json'
        args = ('--stage', self.stage, '--extracted', extracted, '--report', report,
                '--engine-sources', self.sources)
        self.run_package_script('verify_bundle.py', *args)
        self.assertEqual(len(overlay.load(report)['rebuiltRuntimeEngines']), 2)
        (extracted / 'rime_1.dll').rename(extracted / 'unexpected-engine.dll')
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            self.run_package_script('verify_bundle.py', *args)
        self.assertIn('one runtime for each architecture', failure.exception.stderr)

    def test_rejects_an_unverified_engine_machine(self):
        root = self.engines / 'x64'
        raw = image(overlay.MACHINES['x86'], 'wrong-architecture')
        write(root / 'dist/lib/rime.dll', raw)
        record = overlay.load(root / 'build-result.json')
        save(root / 'build-result.json', record | {'sha256': sha(raw)})
        with self.assertRaisesRegex(ValueError, 'architecture proof'):
            self.apply()

    def test_rejects_stale_native_manifest_or_missing_notice(self):
        record = self.engines / 'x86/build-result.json'
        original = overlay.load(record)
        save(record, original | {'manifestSha256': '0' * 64})
        with self.assertRaisesRegex(ValueError, 'architecture proof'):
            overlay.checked_engine(self.engines / 'x86', 'x86', 'engine-r5', self.native, self.sources)
        save(record, original)
        (self.engines / 'x86/licenses/engine-notice.txt').unlink()
        with self.assertRaisesRegex(ValueError, 'changed a notice'):
            self.apply()

    def test_rejects_missing_engine_inputs(self):
        with self.assertRaisesRegex(ValueError, 'required together'):
            overlay.apply(self.stage, self.products, self.products, REF)


if __name__ == '__main__':
    unittest.main()
