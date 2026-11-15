"""Apply two same-run server builds while retaining all other pinned images."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text('utf-8-sig'))


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def machine(path):
    raw = path.read_bytes()
    if len(raw) < 64 or raw[:2] != b'MZ':
        raise ValueError('Invalid executable header')
    offset = struct.unpack_from('<I', raw, 0x3c)[0]
    if offset + 6 > len(raw) or raw[offset:offset + 4] != b'PE\0\0':
        raise ValueError('Invalid PE header')
    return struct.unpack_from('<H', raw, offset + 4)[0]


def verify_checksums(root):
    declared = {}
    for line in (root / 'SHA256SUMS.txt').read_text('utf-8-sig').splitlines():
        sha, name = line.split('  ', 1)
        if (not re.fullmatch('[a-f0-9]{64}', sha) or name in declared
                or '\\' in name or ':' in name or '..' in Path(name).parts):
            raise ValueError('Invalid server artifact checksum entry')
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()) or digest(path) != sha:
            raise ValueError('Server artifact bytes differ')
        declared[name] = sha
    actual = {path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_file()}
    if actual != set(declared) | {'SHA256SUMS.txt'}:
        raise ValueError('Server artifact file set differs')


def apply(stage, overlays, repository, source_ref, run_id):
    if not re.fullmatch('[a-f0-9]{40}', source_ref) or run_id < 1:
        raise ValueError('An exact source commit and run are required')
    inputs = load(repository / 'installer/bundle-inputs.json')
    native_inputs = load(repository / 'native/notification-inputs.json')
    native_manifest = load(repository / 'native/source-manifest.json')
    specs = inputs['serverOverlays']['architectures']
    expected_paths = {'x64': 'StellaeServer.exe', 'x86': 'Win32/StellaeServer.exe'}
    if set(specs) != set(expected_paths):
        raise ValueError('Expected the x64 and Win32 server overlays')
    base = load(stage / 'base-package-license-index.json')
    base_images = {row['path']: row for row in base['files']
                   if Path(row['path']).suffix.lower() in {'.exe', '.dll', '.ime'}}
    actual_images = {path.relative_to(stage).as_posix(): digest(path)
                     for path in stage.rglob('*') if path.is_file()
                     and path.suffix.lower() in {'.exe', '.dll', '.ime'}
                     and not path.relative_to(stage).as_posix().startswith('archives/')}
    if set(actual_images) != set(base_images):
        raise ValueError('The original native image set differs')
    for name, sha in actual_images.items():
        if sha != base_images[name]['sha256']:
            raise ValueError('An original native image differs: ' + name)
    provenance = load(stage / 'bundle-provenance.json')
    changes = []
    for arch, installed in expected_paths.items():
        spec = specs[arch]
        root = overlays / arch
        verify_checksums(root)
        record = load(root / 'validation.json')
        source = root / 'StellaeServer.exe'
        old_sha = base_images[installed]['sha256']
        if (spec['installedPath'] != installed or spec['baseSha256'] != old_sha
                or digest(stage / installed) != old_sha):
            raise ValueError('The server replacement baseline differs')
        if (not record['passed'] or record['architecture'] != arch
                or record['commit'] != source_ref or int(record['run']) != run_id
                or record['sourceVersion'] != inputs['frontendVersion']
                or digest(source) != record['serverSha256']
                or machine(source) != spec['machine']):
            raise ValueError('The server build is not from this source and run')
        if (record['candidateCppSha256'] != native_inputs['modeIconOverlay']['candidateCppSha256']
                or record['candidateHeaderSha256'] != native_inputs['modeIconOverlay']['candidateHeaderSha256']
                or record['completePatchSha256'] != native_manifest['patches'][0]['sha256']
                or record['engineUsedForImportLibrarySha256'] != native_inputs['architectures'][arch]['engineSha256']
                or record['notificationChecks'] != 47 or record['shiftSnapshotChecks'] != 36
                or record['modeIconChecks'] != 49):
            raise ValueError('The server source or finite regression proof differs')
        for key in ('engineRebuilt', 'engineBundled', 'tsfBuilt', 'clientsBuilt', 'profilesIncluded', 'installed'):
            if record[key] is not False:
                raise ValueError('A server-only build exceeded its scope')
        archive = root / 'assembled-source.zip'
        if digest(archive) != record['assembledSourceSha256']:
            raise ValueError('The corresponding assembled source differs')
        with zipfile.ZipFile(archive) as zf:
            manifest = json.loads(zf.read('source-archive-manifest.json'))
            if (manifest['publicBuildCommit'] != source_ref
                    or int(manifest['publicBuildRunId']) != run_id):
                raise ValueError('The source archive is from a different build')
            for name, sha in (('RimeWithWeasel/RimeWithWeasel.cpp', record['candidateCppSha256']),
                              ('include/RimeWithWeasel.h', record['candidateHeaderSha256'])):
                if hashlib.sha256(zf.read(name)).hexdigest() != sha:
                    raise ValueError('The source archive does not contain the rebuilt server source')
        origin = {'installed_path': installed, 'source': 'rebuiltServer',
                  'sha256': digest(source), 'original_sha256': old_sha,
                  'source_ref': source_ref, 'source_run': run_id, 'architecture': arch,
                  'corresponding_source': 'server-' + arch + '-source.zip',
                  'assembled_source_sha256': digest(archive),
                  'transformation': 'rebuild the server from the fixed frontend source and mode notification/icon changes',
                  'generated_source_ids': ['project-code']}
        previous = [index for index, row in enumerate(provenance['files'])
                    if row['installed_path'] == installed]
        if (len(previous) != 1
                or provenance['files'][previous[0]]['source'] != 'frontendInstaller'
                or provenance['files'][previous[0]]['sha256'] != old_sha):
            raise ValueError('The original server provenance is not unique or differs')
        shutil.copyfile(source, stage / installed)
        provenance['files'][previous[0]] = origin
        changes.append(origin)
    for name, row in base_images.items():
        expected = next((item['sha256'] for item in changes if item['installed_path'] == name), row['sha256'])
        if digest(stage / name) != expected:
            raise ValueError('A native image outside the reviewed replacement set changed')
    save(stage / 'bundle-provenance.json', provenance)
    result = {'passed': True, 'sourceRef': source_ref, 'runId': run_id,
              'rebuiltServers': changes, 'nativeImages': len(base_images),
              'unchangedNativeImages': len(base_images) - len(changes),
              'runtimeEnginesPreserved': True, 'physicalKeyboardTested': False}
    save(stage / 'server-overlay-verification.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--overlays', type=Path, required=True)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--source-ref', required=True)
    parser.add_argument('--run-id', type=int, required=True)
    args = parser.parse_args()
    print(json.dumps(apply(args.stage, args.overlays, args.repository, args.source_ref, args.run_id)))
