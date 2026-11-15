"""Verify extracted payload bytes and the retained/rebuilt native image set."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text('utf-8-sig'))


def contained(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise SystemExit('The package has an invalid file path')
    return path


def image_machine(path):
    raw = path.read_bytes()
    if len(raw) < 64 or raw[:2] != b'MZ':
        raise SystemExit('Invalid native image header')
    offset = struct.unpack_from('<I', raw, 0x3c)[0]
    if offset + 6 > len(raw) or raw[offset:offset + 4] != b'PE\0\0':
        raise SystemExit('Invalid native PE header')
    return struct.unpack_from('<H', raw, offset + 4)[0]


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--stage', type=Path, required=True)
p.add_argument('--extracted', type=Path, required=True)
p.add_argument('--report', type=Path, required=True)
a = p.parse_args()
files = [path for path in a.extracted.rglob('*') if path.is_file()]
hashes = {digest(path) for path in files}
manifest = load(a.stage / 'package-manifest.json')
shared = (a.stage / 'shared-payload/data').resolve()
profile = load(shared / 'config-source-manifest.json')
profile_records = profile['source_files'] + profile['generated_files']
for entry in profile_records:
    path = contained(shared, entry['path'])
    if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
        raise SystemExit('Installed profile manifest describes stale bytes: ' + entry['path'])
snapshot = contained(a.stage, profile['archive_provenance']['original_manifest'])
if digest(snapshot) != profile['archive_provenance']['original_manifest_sha256']:
    raise SystemExit('Original scheme profile snapshot differs')
installed = {}
for entry in manifest['files']:
    path = contained(a.stage, entry['path'])
    if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
        raise SystemExit('Staged package differs from its manifest: ' + entry['path'])
    if entry['sha256'] not in hashes:
        raise SystemExit('Completed installer is missing declared bytes: ' + entry['path'])
    if entry['installed_path'] in installed:
        raise SystemExit('Duplicate installed payload path')
    installed[entry['installed_path']] = entry
for name in ['package-manifest.json', 'package-license-index.json']:
    if digest(a.stage / name) not in hashes:
        raise SystemExit('Missing installed metadata: ' + name)
for path in files:
    if path.suffix.lower() in {'.pdb', '.dmp', '.log'} or '.userdb' in path.name:
        raise SystemExit('Unexpected runtime or diagnostic file')

provenance = load(a.stage / 'bundle-provenance.json')
inputs = load(a.stage / 'bundle-inputs.json')
base = load(a.stage / 'base-package-license-index.json')
licenses = {row['installed_path']: row for row in load(a.stage / 'package-license-index.json')['files']}
overlay = load(a.stage / 'server-overlay-verification.json')
source_ref = manifest['sourceRef']
if (not re.fullmatch('[a-f0-9]{40}', source_ref)
        or not overlay['passed'] or overlay['sourceRef'] != source_ref
        or not isinstance(overlay['runId'], int) or overlay['runId'] < 1
        or provenance['bundleVersion'] != manifest['bundleVersion']
        or inputs['bundleVersion'] != manifest['bundleVersion']
        or inputs['frontendVersion'] != manifest['frontendVersion']):
    raise SystemExit('Native overlay source or package identity differs')

suffixes = {'.exe', '.dll', '.ime'}
base_images = {row['path']: row for row in base['files'] if Path(row['path']).suffix.lower() in suffixes}
native_rows = [row for row in provenance['files'] if Path(row['installed_path']).suffix.lower() in suffixes]
current = {}
for row in native_rows:
    if row['installed_path'] in current:
        raise SystemExit('Duplicate current native image provenance')
    current[row['installed_path']] = row
staged_images = {path.relative_to(a.stage).as_posix() for path in a.stage.rglob('*')
                 if path.is_file() and path.suffix.lower() in suffixes
                 and not path.relative_to(a.stage).as_posix().startswith('archives/')}
if len(base_images) != 14 or set(current) != set(base_images) or staged_images != set(base_images):
    raise SystemExit('The complete native image set differs')
expected = {'x64': ('StellaeServer.exe', 0x8664), 'x86': ('Win32/StellaeServer.exe', 0x14c)}
specs = inputs['serverOverlays']['architectures']
proof_rows = overlay['rebuiltServers']
if (set(specs) != set(expected) or len(proof_rows) != 2
        or len({row['installed_path'] for row in proof_rows}) != 2
        or overlay['nativeImages'] != 14 or overlay['unchangedNativeImages'] != 12
        or overlay['runtimeEnginesPreserved'] is not True):
    raise SystemExit('Expected exactly two rebuilt and twelve retained images')
proof = {row['installed_path']: row for row in proof_rows}
rebuilt = []
for arch, (name, machine) in expected.items():
    row = current[name]
    spec = specs[arch]
    if (row['source'] != 'rebuiltServer' or proof.get(name) != row
            or spec['installedPath'] != name or spec['machine'] != machine
            or row['original_sha256'] != spec['baseSha256']
            or row['original_sha256'] != base_images[name]['sha256']
            or row['source_ref'] != source_ref or row['source_run'] != overlay['runId']
            or row['architecture'] != arch
            or row['corresponding_source'] != 'server-' + arch + '-source.zip'
            or not re.fullmatch('[a-f0-9]{64}', row['assembled_source_sha256'])):
        raise SystemExit('Rebuilt server provenance differs: ' + name)
    path = contained(a.stage, name)
    if (digest(path) != row['sha256'] or installed[name]['sha256'] != row['sha256']
            or row['sha256'] not in hashes or image_machine(path) != machine):
        raise SystemExit('Rebuilt product differs: ' + name)
    license_row = licenses[name]
    if (license_row['sha256'] != row['sha256']
            or license_row['original_sha256'] != base_images[name]['sha256']
            or license_row['license_record'] != base_images[name]
            or not set(base_images[name].get('source_ids', [])).issubset(license_row['source_ids'])
            or 'project-code' not in license_row['source_ids']):
        raise SystemExit('Rebuilt server inherited notices differ: ' + name)
    rebuilt.append({'path': name, 'sha256': row['sha256'], 'original_sha256': row['original_sha256'],
                    'sourceRef': source_ref, 'runId': row['source_run']})

retained = []
for name, row in current.items():
    if name in proof:
        continue
    if (row['source'] != 'frontendInstaller' or row['sha256'] != base_images[name]['sha256']
            or digest(contained(a.stage, name)) != row['sha256']
            or installed[name]['sha256'] != row['sha256'] or row['sha256'] not in hashes):
        raise SystemExit('Reused product differs: ' + name)
    retained.append({'path': name, 'sha256': row['sha256']})
if len(retained) != 12 or len(rebuilt) != 2:
    raise SystemExit('Native image verification is incomplete')

report = {'format': 'stellae-bundle-extraction-v1', 'passed': True,
          'bundleVersion': manifest['bundleVersion'], 'frontendVersion': manifest['frontendVersion'],
          'sourceRef': source_ref, 'sourceRunId': overlay['runId'],
          'verifiedInputFiles': len(manifest['files']), 'installedProfileRecordsVerified': len(profile_records),
          'extractedFiles': len(files), 'reusedImages': retained, 'rebuiltImages': rebuilt,
          'nativeImages': len(current), 'physicalKeyboardTested': False}
a.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'passed': True, 'verifiedInputFiles': len(manifest['files']),
                  'reusedImages': len(retained), 'rebuiltImages': len(rebuilt)}))
