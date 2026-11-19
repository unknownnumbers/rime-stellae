"""Replace the six frontend images using checked native build artifacts."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
from zipfile import ZipFile


PRODUCTS = {
    'x64': ('stellaex64.dll', 'stellaex64.ime', 'StellaeServer.exe'),
    'x86': ('stellae.dll', 'stellae.ime', 'Win32/StellaeServer.exe'),
}
MACHINES = {'x64': 0x8664, 'x86': 0x014c}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text('utf-8-sig'))


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def image_machine(path):
    raw = path.read_bytes()
    if len(raw) < 64 or raw[:2] != b'MZ':
        raise ValueError(f'Invalid DOS header: {path.name}')
    offset = struct.unpack_from('<I', raw, 0x3c)[0]
    if offset + 6 > len(raw) or raw[offset:offset + 4] != b'PE\0\0':
        raise ValueError(f'Invalid PE header: {path.name}')
    return struct.unpack_from('<H', raw, offset + 4)[0]


def unique(root, name):
    files = list(root.rglob(name))
    if len(files) != 1 or not files[0].is_file() or files[0].is_symlink():
        raise ValueError(f'Expected exactly one native input: {root.name}/{name}')
    return files[0]


def checked_products(product_root, source_root, arch, version, source_files):
    record_path = unique(product_root, 'build-result.json')
    record = load(record_path)
    output = record_path.parent
    if (not record['passed'] or record['architecture'] != arch
            or record['sourceVersion'] != version or record['symbolsBundled']
            or record['engineBundled'] or record['engineRebuilt']
            or record['optInNumericTraceCompiled']):
        raise ValueError(f'Native artifact validation differs: {arch}')
    archive = unique(source_root, 'candidate-source.zip')
    if digest(archive) != record['candidateSourceArchiveSha256']:
        raise ValueError(f'Native source archive bytes differ: {arch}')
    with ZipFile(archive) as source:
        for name, expected in source_files.items():
            if hashlib.sha256(source.read(name)).hexdigest() != expected:
                raise ValueError(f'Corresponding native source differs: {arch}/{name}')
    checked = {}
    for product in record['products']:
        name = product['installedRelativePath']
        if name not in PRODUCTS[arch] or name in checked:
            raise ValueError(f'Unexpected native installed path: {name}')
        path = output / Path(name).name
        if (product['version'] != version or product['machine'] != MACHINES[arch]
                or path.stat().st_size != product['bytes'] or digest(path) != product['sha256']
                or image_machine(path) != MACHINES[arch]):
            raise ValueError(f'Native product bytes differ: {arch}/{name}')
        checked[name] = path, product['sha256']
    if set(checked) != set(PRODUCTS[arch]):
        raise ValueError(f'Incomplete native artifact: {arch}')
    return checked


def apply(stage, products, sources, source_ref):
    if not re.fullmatch('[a-f0-9]{40}', source_ref):
        raise ValueError('Use the exact frontend source revision')
    inputs = load(stage / 'bundle-inputs.json')
    source_files = inputs['nativeFrontend']['sourceFiles']
    if not source_files or any(not re.fullmatch('[a-f0-9]{64}', sha) for sha in source_files.values()):
        raise ValueError('Pin the frontend source changes')
    provenance_path = stage / 'bundle-provenance.json'
    provenance = load(provenance_path)
    base = load(stage / 'base-package-license-index.json')
    base_images = {row['path']: row['sha256'] for row in base['files']
                   if Path(row['path']).suffix.lower() in {'.exe', '.dll', '.ime'}}
    staged = {path.relative_to(stage).as_posix(): digest(path)
              for path in stage.rglob('*') if path.is_file()
              and path.suffix.lower() in {'.exe', '.dll', '.ime'}}
    if staged != base_images:
        raise ValueError('The original native image set differs')
    changes = []
    expected = dict(base_images)
    for arch in PRODUCTS:
        for name, (path, sha) in checked_products(products / arch, sources / arch,
                                                   arch, inputs['frontendVersion'], source_files).items():
            old_sha = base_images[name]
            previous = [index for index, row in enumerate(provenance['files'])
                        if row['installed_path'] == name]
            if (len(previous) != 1 or sha == old_sha
                    or provenance['files'][previous[0]]['sha256'] != old_sha):
                raise ValueError(f'The original native provenance differs: {name}')
            replacement = {
                'installed_path': name, 'source': 'rebuiltFrontend', 'sha256': sha,
                'original_sha256': old_sha, 'source_ref': source_ref, 'architecture': arch,
                'corresponding_source': 'bundle-project-source.zip',
                'transformation': 'rebuild the frontend from the pinned sources and patch',
                'generated_source_ids': ['project-code'],
            }
            shutil.copyfile(path, stage / name)
            expected[name] = sha
            provenance['files'][previous[0]] = replacement
            changes.append(replacement)
    for name, sha in expected.items():
        if digest(stage / name) != sha:
            raise ValueError(f'Native replacement does not match the reviewed set: {name}')
    save(provenance_path, provenance)
    result = {'passed': True, 'sourceRef': source_ref, 'rebuiltImages': changes,
              'nativeImages': len(base_images), 'unchangedNativeImages': len(base_images) - len(changes),
              'runtimeEnginesPreserved': True}
    save(stage / 'server-overlay-verification.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--source-ref', required=True)
    args = parser.parse_args()
    print(json.dumps(apply(args.stage, args.products, args.sources, args.source_ref)))
