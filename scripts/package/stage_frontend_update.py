"""Stage six checked frontend images while leaving installed engines in place.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
from zipfile import ZipFile

from apply_frontend_overlays import checked_products, unique

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = {
    'x64': ('stellaex64.dll', 'stellaex64.ime', 'StellaeServer.exe', 'StellaeDeployer.exe'),
    'x86': ('stellae.dll', 'stellae.ime'),
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source(ref, relative):
    flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    raw = subprocess.run(['git', '-C', str(ROOT), 'show', ref + ':' + relative],
                         capture_output=True, check=True, **flags).stdout
    if (ROOT / relative).read_bytes() != raw:
        raise ValueError('Working source differs from the pinned commit: ' + relative)
    return raw


def stage(x64_build, x86_build, source_ref, output):
    import re
    if not re.fullmatch('[0-9a-f]{40}', source_ref):
        raise ValueError('Use the exact frontend source commit')
    inventory = json.loads(source(source_ref, 'native/frontend-source-files.json'))
    source_files = {row['path']: row['sha256'] for row in inventory['files'] if not row.get('deleted')}
    inputs = json.loads(source(source_ref, 'installer/bundle-inputs.json'))
    builds = {'x64': Path(x64_build), 'x86': Path(x86_build)}
    verified, source_archives = {}, {}
    for arch, directory in builds.items():
        verified[arch] = checked_products(directory, directory, arch, inputs['frontendVersion'],
                                          source_files, client_only=arch == 'x86')
        if set(verified[arch]) != set(PRODUCTS[arch]):
            raise ValueError('The component must contain exactly six frontend images')
        source_archives[arch] = unique(directory, 'candidate-source.zip')
        with ZipFile(source_archives[arch]) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError('Duplicate frontend source archive members')
            for name in names:
                path = PurePosixPath(name)
                if path.is_absolute() or '..' in path.parts or ':' in name or '\\' in name:
                    raise ValueError('Invalid frontend source archive member')
                if path.suffix.lower() in {'.exe', '.dll', '.ime', '.lib', '.obj', '.pdb', '.exp', '.o', '.a', '.so'}:
                    raise ValueError('A source archive contains a prebuilt native image')
            for row in inventory['files']:
                if row.get('deleted') and row['path'] in names:
                    raise ValueError('A deleted native source is present in the archive')

    out = Path(output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows, archives = [], []
    for arch, products in verified.items():
        for name, (path, checksum) in products.items():
            shutil.copyfile(path, out / name)
            rows.append({'path': name, 'architecture': arch, 'bytes': path.stat().st_size,
                         'sha256': checksum, 'machine': 0x8664 if arch == 'x64' else 0x014c})
        directory = out / 'sources'
        directory.mkdir(exist_ok=True)
        relative = 'sources/frontend-' + arch + '-source.zip'
        shutil.copyfile(source_archives[arch], out / relative)
        archives.append({'path': relative, 'sha256': digest(out / relative)})

    helpers = []
    for relative, original in (
            ('Update-Frontend.ps1', 'scripts/package/Update-Frontend.ps1'),
            ('profile-policy/InstallProfilePolicy.ps1', 'installer/InstallProfilePolicy.ps1'),
            ('profile-policy/NativeProfileSnapshot.ps1', 'installer/NativeProfileSnapshot.ps1')):
        path = out / relative
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(source(source_ref, original))
        helpers.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': digest(path)})
    manifest = {'format': 'stellae-frontend-update-v1', 'componentVersion': inputs['bundleVersion'],
                'sourceRef': source_ref, 'buildWorkflowSourceRef': os.getenv('GITHUB_SHA'),
                'files': rows, 'helpers': helpers, 'sourceArchives': archives,
                'runtimeEnginesIncluded': False, 'independent32BitBackendIncluded': False}
    (out / 'frontend-update-inputs.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    shutil.copyfile(ROOT / 'LICENSE', out / 'LICENSE')
    shutil.copytree(ROOT / 'licenses', out / 'licenses')
    return {'passed': True, 'sourceRef': source_ref, 'frontendImages': len(rows),
            'runtimeEnginesIncluded': False, 'independent32BitBackendIncluded': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--x64-build-directory', type=Path, required=True)
    parser.add_argument('--x86-build-directory', type=Path, required=True)
    parser.add_argument('--source-ref', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(stage(args.x64_build_directory, args.x86_build_directory, args.source_ref, args.output)))
