"""Stage a bundle from hash-pinned public source and binary distributions."""
# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import zipfile

DEFAULT_FONT_NAME = 'NotoSansCJK-Regular.ttc'
DEFAULT_FONT_FAMILIES = {
    f'{prefix} {style}'
    for prefix in ('Noto Sans CJK', 'Noto Sans Mono CJK')
    for style in ('JP', 'KR', 'SC', 'TC', 'HK')
}
FONT_INSTALLER_HELPERS = ('Install-CandidateFont.ps1', 'CandidateFontNative.cs')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


def safe_name(name):
    value = PurePosixPath(name)
    if value.is_absolute() or '..' in value.parts or '\\' in name or ':' in name:
        raise ValueError('Unsafe archive path')
    return value


def check_scheme_archive(archive, inputs, source_ref):
    specification = inputs.get('schemes', {})
    if (not re.fullmatch(r'[0-9a-f]{40}', source_ref)
            or specification.get('sourceDirectory') != 'schemes'
            or specification.get('profile') != 'stellae'):
        raise ValueError('Build the base scheme from the exact Stellae source commit.')
    manifest = json.loads(archive.read('package-manifest.json'))
    if (manifest.get('format') != 'stellae-scheme-package-v1'
            or manifest.get('source_ref') != source_ref
            or manifest.get('source_repository') != 'https://github.com/unknownnumbers/rime-stellae'
            or manifest.get('source_prefix') != 'schemes'
            or manifest.get('version') != specification.get('version')
            or manifest.get('profile') != 'stellae'
            or manifest.get('personal_learning_included') is not False
            or manifest.get('compiled_rime_dictionaries_included') is not False):
        raise ValueError('The scheme archive does not belong to this Stellae source commit.')
    names = archive.namelist()
    declared = [entry['path'] for entry in manifest['files']]
    if (len(names) != len(set(names)) or len(declared) != len(set(declared))
            or set(names) != {*declared, 'package-manifest.json'}):
        raise ValueError('The scheme archive members differ from its source manifest.')
    for entry in manifest['files']:
        safe_name(entry['path'])
        raw = archive.read(entry['path'])
        if len(raw) != entry['bytes'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
            raise ValueError('Scheme archive member differs from its source manifest.')
    return manifest


def stage_math_upgrade(repo, stage, archive_path, inputs):
    if digest(archive_path) != inputs['indexedMath']['sha256']:
        raise SystemExit('The indexed math archive differs from the pinned source.')
    upgrade = repo/'installer/migrations/upgrade.json'
    spec = json.loads(upgrade.read_text('utf-8'))
    if spec['format'] != 'stellae-bundle-user-upgrade-v1':
        raise SystemExit('Unexpected user upgrade manifest.')
    migrations = stage/'shared-payload/migrations'
    migrations.mkdir()
    shutil.copyfile(upgrade, migrations/'upgrade.json')
    notices = (
        'AUTHORS-OpenCC.txt', 'LICENSE-CC-BY-SA-4.0.txt', 'LICENSE-OpenCC-Apache-2.0.txt',
        'LICENSE-Unicode-3.0.txt', 'LICENSE-Wikidata-CC0.txt', 'LICENSE-pypinyin-MIT.txt',
        'NOTICE-science-sources.txt', 'NOTICE.txt', 'SOURCE.json',
    )
    with zipfile.ZipFile(archive_path) as archive:
        for name, expected in (
            ('english.tsv', spec['math']['catalogSha256']),
            *[(f'english_index/{row["name"]}', row['sha256']) for row in spec['math']['index']],
        ):
            if hashlib.sha256(archive.read(f'rymcp_dlc/math/{name}')).hexdigest() != expected:
                raise SystemExit(f'The math upgrade archive does not match {name}.')
        for name in (*notices, *[f'english_index/{row["name"]}' for row in spec['math']['index']]):
            target = migrations/'math'/safe_name(name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(f'rymcp_dlc/math/{name}'))


def stage_default_fonts(repo, stage, source):
    manifest_path = source/'font-manifest.json'
    if digest(manifest_path) != digest(repo/'installer/default-fonts/font-manifest.json'):
        raise SystemExit('The default font manifest differs from the reviewed source.')
    manifest = json.loads(manifest_path.read_text('utf-8-sig'))
    if manifest.get('schemaVersion') != 2:
        raise SystemExit('Unsupported default font manifest.')
    files = {row['file']: row for row in manifest['files']}
    notices = {row['file']: row for row in manifest['notices']}
    allowed_notices = {'OFL.txt', 'NOTICE.txt'}
    if (set(files) != {DEFAULT_FONT_NAME} or len(manifest['files']) != 1
            or set(notices) != allowed_notices or len(manifest['notices']) != len(allowed_notices)):
        raise SystemExit('The default font payload must contain one Regular collection and the OFL notice.')
    font = files[DEFAULT_FONT_NAME]
    if (set(font['families']) != DEFAULT_FONT_FAMILIES or len(font['families']) != len(DEFAULT_FONT_FAMILIES)
            or font['role'] != 'primary' or font['version'] != '2.004' or font['license'] != 'OFL-1.1'):
        raise SystemExit('The default font collection identity differs.')
    for name, entry in (files | notices).items():
        path = source/name
        if entry['size'] != path.stat().st_size or entry['sha256'] != digest(path):
            raise SystemExit('Default font input bytes differ from the reviewed manifest: '+name)
    payload = stage/'font-payload'
    payload.mkdir()
    for name in sorted(set(files) | allowed_notices):
        shutil.copyfile(source/name, payload/name)
    shutil.copyfile(manifest_path, payload/'font-manifest.json')
    notice_directory = stage/'font-notices'
    notice_directory.mkdir()
    for name in sorted(allowed_notices):
        shutil.copyfile(source/name, notice_directory/name)
    shutil.copyfile(manifest_path, notice_directory/'font-manifest.json')
    for name in FONT_INSTALLER_HELPERS:
        shutil.copyfile(repo/'scripts/fonts'/name, stage/name)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--official', type=Path, required=True)
    p.add_argument('--schemes', type=Path, required=True)
    p.add_argument('--source-ref', required=True)
    p.add_argument('--indexed-math', type=Path)
    p.add_argument('--default-font-directory', type=Path, help='Directory containing the reviewed offline font collection.')
    p.add_argument('--stage', type=Path, required=True)
    p.add_argument('--repository', type=Path, required=True)
    p.add_argument('--inputs', type=Path, help='Use an explicit review manifest; the release build uses the repository manifest.')
    a = p.parse_args()
    repo = a.repository.resolve()
    inputs = json.loads((a.inputs or repo/'installer/bundle-inputs.json').read_text('utf-8'))
    with zipfile.ZipFile(a.schemes) as archive:
        scheme_manifest = check_scheme_archive(archive, inputs, a.source_ref)
    stage = a.stage
    stage.mkdir(parents=True, exist_ok=False)
    payload = stage/'shared-payload/data'
    payload.mkdir(parents=True)
    if 'indexedMath' in inputs:
        if a.indexed_math is None:
            raise SystemExit('The bundle requires the pinned indexed math archive.')
        stage_math_upgrade(repo, stage, a.indexed_math, inputs)
    if a.default_font_directory is not None:
        stage_default_fonts(repo, stage, a.default_font_directory.resolve())
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
    for config, alias in [('default', 'stellae_bundle_default'), ('weasel', 'stellae_bundle_weasel')]:
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
        font_layer = ('  - rymcp_candidate_font:/patch?\n  - stellae_candidate_font:/patch?\n'
                      if config == 'weasel' and a.default_font_directory is not None else '')
        extension = ('\n# Stellae defaults followed by optional user overrides.\n__patch:\n'
                     f'  - {alias}:/patch\n{font_layer}  - {config}.custom:/patch?\n').encode('utf-8')
        base_file.write_bytes(raw+extension)
        origin = next(row for row in reversed(provenance) if row['installed_path'] == 'data/'+config+'.yaml')
        origin['original_sha256'] = origin['sha256']
        origin['sha256'] = digest(base_file)
        origin['generated_sha256'] = origin['sha256']
        origin['transformation'] = ('append an explicit bundle preset, optional candidate-font preset, and optional user custom patch'
                                    if font_layer else 'append an explicit bundle preset followed by the optional user custom patch')
        origin['generated_source_ids'] = ['project-code']
    profile_file = payload/'config-source-manifest.json'
    profile_raw = profile_file.read_bytes()
    source_profile = stage/'scheme-notices/archive-profile-manifest.json'
    source_profile.write_bytes(profile_raw)
    profile = json.loads(profile_raw)
    renames = {'default.custom.yaml': 'stellae_bundle_default.yaml',
               'weasel.custom.yaml': 'stellae_bundle_weasel.yaml'}
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
    profile['format'] = 'stellae-installed-profile-v2'
    profile['note'] = 'Paths and hashes in source_files/generated_files describe installed shared profile files. The shared and package manifests index the remaining installer resources.'
    profile['archive_provenance'] = {
        'source_repository': scheme_manifest['source_repository'], 'source_ref': a.source_ref,
        'source_prefix': scheme_manifest['source_prefix'],
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
               'inputs': inputs, 'schemeArchive': {'name': a.schemes.name,
                   'sha256': digest(a.schemes), 'source_ref': a.source_ref,
                   'source_prefix': scheme_manifest['source_prefix']}, 'files': provenance})
    resource = stage.parent/'resource'
    resource.mkdir(exist_ok=True)
    shutil.copyfile(repo/'assets/icon/star-core.ico', resource/'weasel.ico')
    (stage/'archives').mkdir()
    print(json.dumps({'sharedFiles': len(files), 'baseFiles': len(base_manifest['files']),
                      'baseNativeImagesStaged': True, 'bundleVersion': inputs['bundleVersion']}))


if __name__ == '__main__':
    main()
