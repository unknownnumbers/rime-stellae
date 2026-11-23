#!/usr/bin/env python3
"""Export the reviewed PC profile using its source manifest.

SPDX-License-Identifier: GPL-3.0-only
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath


def build(source, output):
    source, output = source.resolve(), output.resolve()
    if output.exists() or output == source or output.is_relative_to(source):
        raise ValueError('Choose an absent destination outside the source profile.')
    manifest_name = 'config-source-manifest.json'
    manifest_path = source / manifest_name
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    records = manifest['source_files'] + manifest['generated_files']
    names = [record['path'] for record in records]
    if len(names) != len(set(names)):
        raise ValueError('Duplicate profile manifest paths.')
    payload = []
    for record in records:
        relative = PurePosixPath(record['path'])
        if relative.is_absolute() or '..' in relative.parts or '\\' in record['path']:
            raise ValueError('Invalid profile source path.')
        if any(part in {'.git', 'build', 'logs', '__pycache__'} or '.userdb' in part
               for part in relative.parts):
            raise ValueError('Unexpected profile source path.')
        path = source / record['path']
        if path.is_symlink() or not path.resolve().is_relative_to(source):
            raise ValueError('Profile source escapes its directory.')
        raw = path.read_bytes()
        if len(raw) != record['bytes'] or hashlib.sha256(raw).hexdigest() != record['sha256']:
            raise ValueError('Profile source differs from its manifest: ' + record['path'])
        payload.append((record['path'], raw))
    output.mkdir(parents=True)
    for relative, raw in payload:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
    (output / manifest_name).write_bytes(manifest_path.read_bytes())
    return {'profile_files': len(payload), 'manifests': 1}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    try:
        result = build(arguments.source, arguments.output)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(json.dumps(result))
