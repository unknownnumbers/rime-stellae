"""Stage a bundle from hash-pinned public source and binary distributions."""
# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import zipfile

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


def safe_name(name):
    value = PurePosixPath(name)
    if value.is_absolute() or '..' in value.parts or '\\' in name or ':' in name:
        raise ValueError('Unsafe archive path')
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--official', type=Path, required=True)
    p.add_argument('--schemes', type=Path, required=True)
    p.add_argument('--stage', type=Path, required=True)
    p.add_argument('--repository', type=Path, required=True)
    p.add_argument('--inputs', type=Path, help='Use an explicit review manifest; the release build uses the repository manifest.')
    a = p.parse_args()
    repo = a.repository.resolve()
    inputs = json.loads((a.inputs or repo/'installer/bundle-inputs.json').read_text('utf-8'))
    if not inputs.get('schemes') or digest(a.schemes) != inputs['schemes']['sha256']:
        raise SystemExit('The scheme distribution must have a fixed public URL, commit and SHA256.')
    stage = a.stage
    stage.mkdir(parents=True, exist_ok=False)
    payload = stage/'shared-payload/data'
    payload.mkdir(parents=True)
    by_hash = {}
    for file in a.base.rglob('*'):
        if file.is_file():
            by_hash.setdefault(digest(file), file)
    manifests = [file for file in a.base.rglob('package-manifest.json') if file.is_file()]
    if len(manifests) != 1:
        raise SystemExit('Expected one original package manifest.')
    base_manifest = json.loads(manifests[0].read_text('utf-8-sig'))
    shutil.copyfile(next(a.base.rglob('package-license-index.json')), stage/'base-package-license-index.json')
    provenance = []
    for entry in base_manifest['files']:
        name = safe_name(entry['path']).as_posix()
        if entry['sha256'] not in by_hash:
            raise SystemExit('Missing original installer bytes: '+name)
        target = payload/name[5:] if name.startswith('data/') else stage/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(by_hash[entry['sha256']], target)
        provenance.append({'installed_path': name, 'archive_member': name,
                           'source': 'frontendInstaller', 'sha256': entry['sha256']})
    # Original data remains available without importing unrelated input schemes.
    for name in ['pinyin.yaml', 'stroke.schema.yaml', 'stroke.dict.yaml']:
        source = a.official/'data'/name
        if not source.is_file():
            raise SystemExit('Missing fixed official dependency: '+name)
        shutil.copyfile(source, payload/name)
        provenance.append({'installed_path': 'data/'+name, 'source': 'officialSharedData',
                           'archive_member': 'data/'+name, 'sha256': digest(source)})
    with zipfile.ZipFile(a.schemes) as archive:
        scheme_manifest = json.loads(archive.read('package-manifest.json'))
        if (scheme_manifest['source_ref'] != inputs['schemes']['commit']
                or scheme_manifest['version'] != inputs['bundleVersion']
                or scheme_manifest['profile'] != 'stellae'):
            raise SystemExit('Scheme source provenance differs from the pinned bundle input.')
        for entry in scheme_manifest['files']:
            raw = archive.read(entry['path'])
            if len(raw) != entry['bytes'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
                raise SystemExit('Scheme archive member differs from its manifest.')
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = safe_name(info.filename).as_posix()
            if name.startswith('UserProfile/'):
                relative = name[len('UserProfile/'):]
                if any(token in relative for token in ['.userdb', '.log', '.pdb']) or relative.startswith('build/'):
                    raise SystemExit('Unexpected runtime file in scheme distribution.')
                target = payload/relative
            else:
                target = stage/'scheme-notices'/name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(info))
            provenance.append({'installed_path': ('data/'+relative if name.startswith('UserProfile/')
                                                  else 'scheme-notices/'+name),
                               'source': 'schemes', 'archive_member': name, 'sha256': digest(target)})
    shutil.copyfile(a.schemes, stage/'scheme-notices'/a.schemes.name)
    # The frontend creates empty user default/weasel custom files. Keep bundle
    # presets separate so those empty user files do not hide the base defaults.
    for config, alias in [('default', 'rymcp_bundle_default'), ('weasel', 'rymcp_bundle_weasel')]:
        custom = payload/(config+'.custom.yaml')
        renamed = payload/(alias+'.yaml')
        if renamed.exists() or not custom.is_file():
            raise SystemExit('Unexpected bundle preset source layout.')
        custom.rename(renamed)
        original_path = 'data/'+config+'.custom.yaml'
        origin = next(row for row in reversed(provenance) if row['installed_path'] == original_path)
        origin['installed_path'] = 'data/'+alias+'.yaml'
        origin['original_installed_path'] = original_path
        origin['original_sha256'] = origin['sha256']
        origin['transformation'] = 'byte-exact rename to a namespaced shared preset'
        base_file = payload/(config+'.yaml')
        raw = base_file.read_bytes()
        text = raw.decode('utf-8-sig')
        if any(line.startswith('__patch:') or line.strip() == '...' for line in text.splitlines()):
            raise SystemExit('The fixed shared base needs a reviewed patch layout.')
        extension = ('\n# RymCp defaults followed by optional user overrides.\n__patch:\n'
                     f'  - {alias}:/patch\n  - {config}.custom:/patch?\n').encode('utf-8')
        base_file.write_bytes(raw+extension)
        origin = next(row for row in reversed(provenance) if row['installed_path'] == 'data/'+config+'.yaml')
        origin['original_sha256'] = origin['sha256']
        origin['sha256'] = digest(base_file)
        origin['generated_sha256'] = origin['sha256']
        origin['transformation'] = 'append an explicit bundle preset followed by the optional user custom patch'
        origin['generated_source_ids'] = ['project-code']
    profile_file = payload/'config-source-manifest.json'
    profile_raw = profile_file.read_bytes()
    source_profile = stage/'scheme-notices/archive-profile-manifest.json'
    source_profile.write_bytes(profile_raw)
    profile = json.loads(profile_raw)
    renames = {'default.custom.yaml': 'rymcp_bundle_default.yaml',
               'weasel.custom.yaml': 'rymcp_bundle_weasel.yaml'}
    for group in ['source_files', 'generated_files']:
        for entry in profile[group]:
            original_name = entry['path']
            original_hash = entry['sha256']
            entry['archive_path'] = 'UserProfile/'+original_name
            entry['archive_sha256'] = original_hash
            entry['archive_bytes'] = entry['bytes']
            entry['path'] = renames.get(original_name, original_name)
            installed_file = payload/entry['path']
            entry['sha256'] = digest(installed_file)
            entry['bytes'] = installed_file.stat().st_size
            if entry['path'] != original_name:
                entry['bundle_transformation'] = 'byte-exact rename to a namespaced shared preset'
            elif entry['sha256'] != original_hash:
                entry['bundle_transformation'] = 'append the bundle preset followed by the optional user patch'
    profile['format'] = 'stellae-rymcp-installed-profile-v1'
    profile['note'] = 'Paths and hashes in source_files/generated_files describe installed shared profile files. The shared and package manifests index the remaining installer resources.'
    profile['archive_provenance'] = {
        'source_repository': scheme_manifest['source_repository'], 'source_ref': inputs['schemes']['commit'],
        'original_manifest': 'scheme-notices/archive-profile-manifest.json',
        'original_manifest_sha256': hashlib.sha256(profile_raw).hexdigest(),
        'repository_manifest': 'scheme-notices/source-config-manifest.json',
        'reference_root': 'installation directory',
    }
    profile.setdefault('official_shared_data', {})
    profile['official_shared_data']['source_details'] = 'scheme-notices/docs/sources/shared-config-sources.md'
    profile['official_shared_data']['scope_description'] = 'Original source dependencies before bundle adaptation; installed hashes are recorded in the profile file lists.'
    write_json(profile_file, profile)
    origin = next(row for row in reversed(provenance) if row['installed_path'] == 'data/config-source-manifest.json')
    origin['original_sha256'] = origin['sha256']
    origin['sha256'] = digest(profile_file)
    origin['generated_sha256'] = origin['sha256']
    origin['transformation'] = 'render installed profile paths and hashes after preset renaming and base adaptation'
    origin['generated_source_ids'] = ['project-code']
    provenance.append({'installed_path': 'scheme-notices/archive-profile-manifest.json',
                       'source': 'schemes', 'archive_member': 'UserProfile/config-source-manifest.json',
                       'sha256': hashlib.sha256(profile_raw).hexdigest()})
    for name in ['install.nsi', 'bundle.nsi', 'BundleData.ps1', 'InstallProfilePolicy.ps1',
                 'NativeProfileSnapshot.ps1', 'stellae_identity.nsh', 'bundle-inputs.json']:
        shutil.copyfile(repo/'installer'/name, stage/name)
    write_json(stage/'bundle-inputs.json', inputs)
    files = [{'path': file.relative_to(payload).as_posix(), 'bytes': file.stat().st_size,
              'sha256': digest(file)} for file in sorted(payload.rglob('*')) if file.is_file()]
    predecessors = [{'path': row['path'][len('data/'):], 'bytes': row['bytes'], 'sha256': row['sha256']}
                    for row in base_manifest['files'] if row['path'].startswith('data/')]
    write_json(stage/'shared-payload/shared-manifest.json',
               {'format': 'stellae-shared-payload-v1', 'bundleVersion': inputs['bundleVersion'],
                'predecessors': predecessors, 'files': files})
    write_json(stage/'bundle-provenance.json', {'format': 'stellae-bundle-provenance-v1',
               'bundleVersion': inputs['bundleVersion'], 'frontendVersion': inputs['frontendVersion'],
               'scope': 'Layered public input records. Later records for an installed path supersede earlier input records; the payload license index records the final package bytes.',
               'inputs': inputs, 'files': provenance})
    resource = stage.parent/'resource'
    resource.mkdir(exist_ok=True)
    shutil.copyfile(repo/'assets/icon/star-core.ico', resource/'weasel.ico')
    (stage/'archives').mkdir()
    print(json.dumps({'sharedFiles': len(files), 'baseFiles': len(base_manifest['files']),
                      'coreBinariesReused': True, 'bundleVersion': inputs['bundleVersion']}))


if __name__ == '__main__':
    main()
