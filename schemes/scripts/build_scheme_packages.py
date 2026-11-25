#!/usr/bin/env python3
"""Package explicit Stellae scheme files without reading an installed profile.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import posixpath
from pathlib import Path, PurePosixPath
import re
import subprocess
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_REPOSITORY = 'https://github.com/unknownnumbers/rime-stellae'
SOURCE_PREFIX = 'schemes'
OFFICIAL = ROOT / 'config/official-weasel'
FORBIDDEN_PARTS = {'.git', 'build', 'logs', '__pycache__'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_file(path):
    relative = PurePosixPath(path)
    if relative.is_absolute() or '..' in relative.parts or '\\' in path:
        raise ValueError(f'Invalid source path: {path}')
    if any(part in FORBIDDEN_PARTS or part.endswith('.userdb') for part in relative.parts):
        raise ValueError(f'Excluded source path: {path}')
    resolved = ROOT / path
    if resolved.is_symlink() or not resolved.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError(f'Source escapes the repository: {path}')
    if not resolved.is_file():
        raise ValueError(f'Missing source file: {path}')
    return resolved


def profile_files(profile):
    if profile == 'stellae':
        manifest_path = 'config/pc/config-source-manifest.json'
        manifest = json.loads(source_file(manifest_path).read_text('utf-8'))
        records = manifest['source_files'] + manifest['generated_files']
        files = {record['path']: record for record in records}
        if len(files) != len(records):
            raise ValueError('Duplicate PC profile manifest entries')
        entries = []
        for path, record in sorted(files.items()):
            name = 'config/pc/' + path
            data = source_file(name).read_bytes()
            if digest(data) != record['sha256'] or len(data) != record['bytes']:
                raise ValueError(f'PC profile manifest differs: {name}')
            entries.append(('UserProfile/' + path, name))
        entries.append(('UserProfile/config-source-manifest.json', manifest_path))
        return entries
    manifest_path = 'config/official-weasel/profile-manifest.json'
    manifest = json.loads(source_file(manifest_path).read_text('utf-8'))
    entries = []
    seen = set()
    for record in manifest['files']:
        path = record['path']
        if path in seen:
            raise ValueError('Duplicate official profile manifest entry')
        seen.add(path)
        name = 'config/official-weasel/' + path
        data = source_file(name).read_bytes()
        if digest(data) != record['sha256'] or len(data) != record['bytes']:
            raise ValueError(f'Official profile manifest differs: {name}')
        if path.startswith('samples/'):
            entries.append((path, name))
            entries.append(('FreshUserProfile/' + path.removeprefix('samples/'), name))
        else:
            entries.append(('payload/' + path, name))
            entries.append(('FreshUserProfile/' + path, name))
    entries.append(('profile-manifest.json', manifest_path))
    return entries


def prepare_official(destination):
    if destination.exists():
        raise ValueError('Fresh profile destination already exists')
    entries = [(path.removeprefix('FreshUserProfile/'), source)
               for path, source in profile_files('official-weasel')
               if path.startswith('FreshUserProfile/')]
    destination.mkdir(parents=True)
    for path, source in entries:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source_file(source).read_bytes())
    (destination / '.synthetic-profile.json').write_text(
        json.dumps({'format': 'rymcp-synthetic-profile-v1', 'profile': 'official-weasel',
                    'learning': 'created only by fixed test cases'}) + '\n', 'utf-8')


def rendered_markdown(data, source_path, source_ref):
    text = data.decode('utf-8-sig')
    def replace(match):
        target = match.group(2)
        if not target or target.startswith('#') or re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target):
            return match.group(0)
        relative, separator, anchor = target.partition('#')
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(source_path), relative))
        url = (SOURCE_REPOSITORY + '/blob/' + source_ref + '/'
               + urllib.parse.quote(posixpath.normpath(posixpath.join(SOURCE_PREFIX, resolved)), safe='/'))
        if separator:
            url += '#' + anchor
        return match.group(1) + url + match.group(3)
    return re.sub(r'(\[[^\]]*\]\()([^\s)]+)(\))', replace, text).encode('utf-8')


def package(profile, output_dir, version, source_ref):
    source_index = json.loads(source_file('licenses/file-licenses.json').read_text('utf-8'))
    license_records = {record['path']: record for record in source_index['files']}
    mappings = profile_files(profile)
    for name in ('LearningStore.ps1', 'LearningStoreNative.cs', 'LearningStore.lua',
                 'DlcNamespace.ps1', 'README.md'):
        mappings.append(('tools/upgrade/' + name, 'scripts/upgrade/' + name))
    if profile == 'stellae':
        mappings.append(('source-config-manifest.json', 'config/pc/config-source-manifest.json'))
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md', 'README.en.md', 'README.zh-SC.md'):
        mappings.append((name, name))
    mappings.append(('source-file-licenses.json', 'licenses/file-licenses.json'))
    for path in sorted(license_records):
        if path.startswith('licenses/') or path.startswith('docs/sources/'):
            mappings.append((path, path))
    for path in ('docs/PC.md', 'docs/BUILD.md', 'docs/STRUCTURE.md', 'docs/official-weasel.md'):
        mappings.append((path, path))
    mappings.append(('native/source-manifest.json', 'native/source-manifest.json'))
    mappings.append(('INSTALL.md', 'docs/official-weasel.md' if profile == 'official-weasel' else 'docs/PC.md'))
    source_destinations = {}
    for destination, source in mappings:
        source_destinations.setdefault(source, destination)
    def license_reference(reference):
        if reference in source_destinations:
            return source_destinations[reference]
        if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', reference):
            return reference
        return (SOURCE_REPOSITORY + '/blob/' + source_ref + '/'
                + urllib.parse.quote(posixpath.join(SOURCE_PREFIX, reference), safe='/#'))
    payload, records, licensed = {}, [], []
    for destination, source in sorted(mappings):
        if destination in payload:
            raise ValueError(f'Duplicate archive path: {destination}')
        data = source_file(source).read_bytes()
        if source not in license_records:
            raise ValueError(f'File has no source license record: {source}')
        transformed = source.endswith('.md') and license_records[source]['kind'] == 'project-explanatory-document'
        if transformed:
            data = rendered_markdown(data, source, source_ref)
        payload[destination] = data
        records.append({'path': destination, 'source_path': source,
                        'bytes': len(data), 'sha256': digest(data),
                        'source_sha256': digest(source_file(source).read_bytes()),
                        'transformation': 'relative Markdown links resolved to pinned source'
                                          if transformed else 'byte-exact copy',
                        'license_index': 'package-license-index.json'})
        license_record = copy.deepcopy(license_records[source])
        license_record['path'] = destination
        for key in ('references', 'notices', 'evidence'):
            if key in license_record:
                license_record[key] = [license_reference(path) for path in license_record[key]]
        licensed.append({'path': destination, 'source_path': source,
                         'bytes': len(data), 'sha256': digest(data),
                         'license': license_record})
    if profile == 'stellae':
        manifest_name = 'UserProfile/config-source-manifest.json'
        original_manifest = payload[manifest_name]
        distributed_manifest = json.loads(original_manifest)
        changed = []
        for record in distributed_manifest['source_files'] + distributed_manifest['generated_files']:
            name = 'UserProfile/' + record['path']
            data = payload[name]
            if digest(data) != record['sha256'] or len(data) != record['bytes']:
                source_record = next(item for item in records if item['path'] == name)
                if source_record['transformation'] != 'relative Markdown links resolved to pinned source':
                    raise ValueError(f'Unexpected profile transformation: {name}')
                record['repository_sha256'] = record['sha256']
                record['sha256'], record['bytes'] = digest(data), len(data)
                record['archive_transformation'] = source_record['transformation']
                changed.append(record['path'])
        distributed_manifest['archive_provenance'] = {
            'source_repository': SOURCE_REPOSITORY, 'source_prefix': SOURCE_PREFIX,
            'source_ref': source_ref, 'original_manifest': 'source-config-manifest.json',
            'original_manifest_sha256': digest(original_manifest),
            'rendered_documentation': changed,
            'scope': 'Hashes describe distributed UserProfile files; code, data and retained notices are byte-exact source copies.'}
        data = (json.dumps(distributed_manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        payload[manifest_name] = data
        for record in records:
            if record['path'] == manifest_name:
                record['bytes'], record['sha256'] = len(data), digest(data)
                record['transformation'] = 'distributed documentation hashes and pinned source provenance'
        for record in licensed:
            if record['path'] == manifest_name:
                record['bytes'], record['sha256'] = len(data), digest(data)
    for name in ('package-manifest.json', 'package-license-index.json'):
        licensed.append({'path': name, 'source_path': 'scripts/build_scheme_packages.py',
                         'license': {'path': name, 'kind': 'generated-package-metadata',
                                     'project_license': 'GPL-3.0-only', 'references': ['LICENSE']}})
    package_index = {'format': 'stellae-scheme-package-license-v1', 'source_ref': source_ref,
                     'sources': source_index['sources'], 'files': licensed}
    index_data = (json.dumps(package_index, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    payload['package-license-index.json'] = index_data
    records.append({'path': 'package-license-index.json', 'source_path': 'licenses/file-licenses.json',
                    'bytes': len(index_data), 'sha256': digest(index_data),
                    'transformation': 'archive path mapping; source records retained',
                    'license_index': 'package-license-index.json'})
    manifest = {'format': 'stellae-scheme-package-v1', 'profile': profile, 'version': version,
                'source_repository': SOURCE_REPOSITORY, 'source_prefix': SOURCE_PREFIX,
                'source_ref': source_ref, 'personal_learning_included': False,
                'compiled_rime_dictionaries_included': False, 'files': records}
    payload['package-manifest.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    output_dir.mkdir(parents=True, exist_ok=True)
    suffix = 'schemes' if profile == 'stellae' else 'official-weasel-schemes'
    filename = output_dir / f'stellae-{version}-{suffix}.zip'
    if filename.exists():
        raise ValueError(f'Archive already exists: {filename.name}')
    with zipfile.ZipFile(filename, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payload.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    with zipfile.ZipFile(filename) as archive:
        if archive.testzip() is not None:
            raise ValueError('Archive integrity check failed')
        for record in records:
            if digest(archive.read(record['path'])) != record['sha256']:
                raise ValueError('Archive hash differs from manifest')
    return {'name': filename.name, 'bytes': filename.stat().st_size,
            'sha256': digest(filename.read_bytes()), 'files': len(payload)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--profile', choices=('all', 'stellae', 'official-weasel'), default='all')
    parser.add_argument('--source-ref', help='Pinned source commit, defaults to repository HEAD')
    parser.add_argument('--prepare-official-dir', type=Path, help='Create a fresh synthetic profile, without installing it')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.version):
        parser.error('Invalid version')
    if args.prepare_official_dir:
        prepare_official(args.prepare_official_dir.resolve())
        print(json.dumps({'prepared': 'fresh official-weasel synthetic profile'}))
        return
    if not args.output_dir:
        parser.error('--output-dir is required when packaging')
    source_ref = args.source_ref or subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', source_ref):
        parser.error('--source-ref must be a full commit SHA')
    profiles = ['stellae', 'official-weasel'] if args.profile == 'all' else [args.profile]
    results = [package(profile, args.output_dir.resolve(), args.version, source_ref) for profile in profiles]
    print(json.dumps({'packages': results}, ensure_ascii=False))


if __name__ == '__main__':
    main()
