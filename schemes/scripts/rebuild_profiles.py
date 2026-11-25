#!/usr/bin/env python3
"""Generate both scheme profiles from one reviewed source and explicit adapters.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path, PurePosixPath
import re


FORBIDDEN_PARTS = {'.git', '.codex', '.agents', 'build', 'sync', 'logs', 'backups', '__pycache__'}
FORBIDDEN_NAMES = {'user.yaml', 'installation.yaml'}
REQUIRED_INPUTS = {
    'default.custom.yaml', 'cn_stellae.custom.yaml', 'jp_stellae.schema.yaml', 'rime.lua', 'stellae.custom.yaml',
    'stellae/defaults.yaml', 'stellae/chinese.yaml', 'stellae/english.yaml',
    'stellae/japanese.yaml', 'stellae/tools.yaml', 'stellae/appearance.yaml', 'stellae/spelling.yaml',
    'key_bindings.yaml', 'punctuation.yaml', 'symbols.yaml',
    'opencc/s2t.json', 'opencc/STCharacters.ocd2', 'opencc/STPhrases.ocd2',
    'source-dependencies.json',
}
CTRL_SPACE_LINE = '    - {when: always, accept: Control+space, toggle: ascii_mode}\n'
ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def refresh_source_manifest(root, version=None):
    """Inventory maintained runtime inputs after reviewed source edits."""
    path = root / 'config-source-manifest.json'
    manifest = json.loads(path.read_bytes())
    if version is not None:
        if not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}\.\d+', version):
            raise ValueError('Use a dated scheme version with an explicit revision.')
        manifest['scheme_version'] = version
    generated = {'lua/data/cn_forms.lua', 'lua/data/cn_extra_forms.lua',
                 'lua/cn/cn_neighbor_keys.lua'}
    rows = []
    for candidate in sorted(root.rglob('*')):
        if candidate.is_symlink():
            raise ValueError('Maintained profile inputs must not be symbolic links.')
        if not candidate.is_file() or candidate == path:
            continue
        relative = candidate.relative_to(root).as_posix()
        if '__pycache__' in candidate.relative_to(root).parts:
            continue
        raw = source_path(root, relative).read_bytes()
        rows.append({'path': relative, 'bytes': len(raw), 'sha256': digest(raw)})
    manifest['source_files'] = [row for row in rows if row['path'] not in generated]
    manifest['generated_files'] = [row for row in rows if row['path'] in generated]
    manifest['allowlisted_source_files'] = len(rows)
    path.write_bytes(json_bytes(manifest))
    return {'source_files': len(rows), 'generated_files': len(manifest['generated_files']),
            'scheme_version': manifest['scheme_version']}


def source_path(root, relative):
    name = PurePosixPath(relative)
    if name.is_absolute() or '..' in name.parts or '\\' in relative:
        raise ValueError(f'Invalid source path: {relative}')
    if name.name in FORBIDDEN_NAMES or any(
        part in FORBIDDEN_PARTS or part.endswith('.userdb') for part in name.parts
    ) or relative.startswith('stellae_dlc/'):
        raise ValueError(f'Not a base scheme source: {relative}')
    path = root / relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f'Missing or redirected source: {relative}')
    return path


def load_inputs(root):
    manifest_raw = (root / 'config-source-manifest.json').read_bytes()
    manifest = json.loads(manifest_raw)
    records = manifest['source_files'] + manifest['generated_files']
    inputs = {}
    for record in records:
        relative = record['path']
        if relative in inputs:
            raise ValueError(f'Duplicate maintained source: {relative}')
        data = source_path(root, relative).read_bytes()
        if len(data) != record['bytes'] or digest(data) != record['sha256'].lower():
            raise ValueError(f'Maintained source manifest differs: {relative}')
        inputs[relative] = data
    missing = REQUIRED_INPUTS - inputs.keys()
    if missing:
        raise ValueError(f'Maintained source lacks fixed inputs: {sorted(missing)}')
    dependencies = json.loads(inputs['source-dependencies.json'])
    for record in dependencies['files']:
        data = inputs[record['path']]
        if len(data) != record['bytes'] or digest(data) != record['sha256']:
            raise ValueError(f'Fixed dependency differs: {record["path"]}')
        for notice in record.get('notices', []):
            if notice not in inputs:
                raise ValueError(f'Fixed dependency notice missing: {notice}')
    for relative, raw in inputs.items():
        if relative == 'rime.lua' or relative.startswith('lua/') and relative.endswith('.lua'):
            for module in re.findall(r"\brequire\s*\(?\s*['\"]([A-Za-z0-9_.]+)['\"]", raw.decode('utf-8')):
                target = 'lua/' + module.replace('.', '/') + '.lua'
                if target not in inputs:
                    raise ValueError(f'Unresolved Lua module in {relative}: {module}')
    return manifest, manifest_raw, inputs


def edit_text(raw, callback):
    eol = '\r\n' if b'\r\n' in raw else '\n'
    text = callback(raw.decode('utf-8').replace('\r\n', '\n'))
    return text.replace('\n', eol).encode('utf-8')


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Profile adapter anchor changed: {old!r}')
    return text.replace(old, new)


def check_common_contract(inputs):
    def switch_keys(relative, header, expected):
        text = inputs[relative].decode('utf-8').replace('\r\n', '\n')
        if text.count(header) != 1:
            raise ValueError(f'Expected one switch-key block: {relative}')
        indent = len(header) - len(header.lstrip(' '))
        block = []
        for line in text.split(header, 1)[1].splitlines():
            if line.strip() and not line.lstrip().startswith('#') and len(line) - len(line.lstrip(' ')) <= indent:
                break
            block.append(line)
        for key, value in expected.items():
            fields = re.findall(r'^' + ' ' * (indent + 2) + re.escape(key) + r': (\S+)\s*$', '\n'.join(block), re.MULTILINE)
            if fields != [value]:
                raise ValueError(f'Unexpected switch behavior: {relative} {key}, expected {value}')
    pc_keys = {'Shift_L': 'noop', 'Shift_R': 'noop', 'Caps_Lock': 'noop'}
    switch_keys('stellae/defaults.yaml', '    switch_key:\n', pc_keys)
    switch_keys('stellae/chinese.yaml', '  ascii_composer/switch_key:\n', pc_keys)
    switch_keys('jp_stellae.schema.yaml', '  switch_key:\n',
                {'Shift_L': 'noop', 'Shift_R': 'inline_ascii', 'Caps_Lock': 'noop'})
    schemas = re.findall(r'^    - schema: (\S+)\s*$', inputs['stellae/defaults.yaml'].decode('utf-8'), re.MULTILINE)
    if schemas != ['cn_stellae', 'jp_stellae']:
        raise ValueError('The shared preset must contain the two maintained schemas.')


def official_pc_settings(text):
    if 'accept: Control+space' in text:
        raise ValueError('Chinese defaults must not own the default Ctrl+Space binding.')
    return replace_once(text, '  translator/use_stock_word_completion: false\n',
                        '  translator/use_stock_word_completion: true\n')


def official_appearance(text):
    start = text.index('  menu/page_size: 5\n')
    end = text.index('\njapanese:\n', start)
    block = text[start:end]
    keys = re.findall(r'^  ([^\s][^\n]*?):(?: |$)', block, flags=re.MULTILINE)
    if set(keys) != {'menu/page_size', 'menu/chinese_page_size', 'menu/english_page_size', 'style/mode_layout'}:
        raise ValueError('Unexpected fields inside the reviewed dynamic layout block.')
    text = text[:start] + '  menu/page_size: 6\n' + text[end:]
    return official_weasel_palette(text)


def official_weasel_palette(text):
    """Patch individual themes while retaining the official host's catalog."""
    lines = text.splitlines(keepends=True)
    anchors = [index for index, line in enumerate(lines) if line == '  preset_color_schemes:\n']
    if len(anchors) != 1 or text.count('\nweasel:\n') != 1:
        raise ValueError('Official appearance palette anchor changed.')
    start = anchors[0]
    if start <= lines.index('weasel:\n'):
        raise ValueError('Official palette must be inside the frontend patch section.')
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line.lstrip().startswith('#') and len(line) - len(line.lstrip(' ')) <= 2:
            end = index
            break
    replacement = []
    themes = []
    for line in lines[start + 1:end]:
        match = re.fullmatch(r'    ([A-Za-z0-9_-]+):\n', line)
        if match:
            themes.append(match.group(1))
            replacement.append('  preset_color_schemes/' + line[4:])
        elif line.startswith('    '):
            replacement.append(line[2:])
        elif not line.strip() or line.lstrip().startswith('#'):
            replacement.append(line)
        else:
            raise ValueError('Unexpected curated theme indentation.')
    if themes != ['reference_gray', 'stellae_sakura', 'stellae_lavender',
                  'stellae_night', 'stellae_crimson', 'stellae_mono']:
        raise ValueError('Official palette adapter requires the reviewed theme set.')
    return ''.join(lines[:start] + replacement + lines[end:])


def adapt_profile(inputs, name, specification):
    result = dict(inputs)
    if name == 'official-weasel':
        if specification['stock_word_completion'] is not True or specification['ctrl_space_owner'] != 'official-client':
            raise ValueError('Unexpected official capability specification.')
        # The official host retains its native frontend configuration ID.
        if 'weasel.custom.yaml' in result:
            raise ValueError('The common profile must have one appearance override entrypoint.')
        result['weasel.custom.yaml'] = result.pop('stellae.custom.yaml')
        result['stellae/chinese.yaml'] = edit_text(result['stellae/chinese.yaml'], official_pc_settings)
        result['stellae/appearance.yaml'] = edit_text(result['stellae/appearance.yaml'], official_appearance)
        result['stellae/defaults.yaml'] = edit_text(result['stellae/defaults.yaml'],
            lambda text: replace_once(text, CTRL_SPACE_LINE, ''))
        style = result['stellae/appearance.yaml'].decode('utf-8')
        for setting in ('"style/inline_preedit": false', '"style/horizontal": false'):
            if setting not in style:
                raise ValueError(f'Official default style must retain {setting}.')
    elif name == 'stellae':
        if specification['stock_word_completion'] is not False:
            raise ValueError('Unexpected Stellae capability specification.')
        text = result['stellae/chinese.yaml'].decode('utf-8').replace('\r\n', '\n')
        if text.count('  translator/use_stock_word_completion: false\n') != 1:
            raise ValueError('Stellae source must explicitly select its native completion capability.')
        default = result['stellae/defaults.yaml'].decode('utf-8').replace('\r\n', '\n')
        if default.count(CTRL_SPACE_LINE) != 1 or 'accept: Control+space' in text:
            raise ValueError('Stellae Ctrl+Space must be defined once in its default preset.')
    else:
        raise ValueError(f'Unknown scheme profile: {name}')
    return {('samples/' + relative if relative in specification['sample_files'] else relative): raw
            for relative, raw in result.items()}


def write_profile(destination, payload, manifest, source_manifest_sha, name):
    if destination.exists():
        raise ValueError(f'Profile output already exists: {destination}')
    destination.mkdir(parents=True)
    records = []
    for relative, raw in sorted(payload.items()):
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        records.append({'path': relative, 'bytes': len(raw), 'sha256': digest(raw)})
    if name == 'stellae':
        metadata = {
            'format': 'rymcp-public-config-v2', 'scheme_version': manifest['scheme_version'],
            'allowlisted_source_files': len(records), 'source_files': records, 'generated_files': [],
            'maintenance_source_manifest_sha256': source_manifest_sha,
            'scope': 'Generated base scheme sources. Optional modules and personal files are not included.',
        }
        metadata_name = 'config-source-manifest.json'
    else:
        metadata = {'format': 'rymcp-official-profile-v2', 'version': manifest['scheme_version'],
                    'maintenance_source_manifest_sha256': source_manifest_sha, 'files': records}
        metadata_name = 'profile-manifest.json'
    (destination / metadata_name).write_bytes(json_bytes(metadata))
    return {'path': destination.name, 'files': len(records), 'manifest': metadata_name,
            'manifest_sha256': digest(json_bytes(metadata))}


def maintained_official(manifest, manifest_raw, inputs, specifications, check):
    """Refresh/check the derived official profile without rewriting common inputs."""
    destination = ROOT / 'config/official-weasel'
    payload = adapt_profile(inputs, 'official-weasel', specifications['profiles']['official-weasel'])
    records = [{'path': path, 'bytes': len(raw), 'sha256': digest(raw)}
               for path, raw in sorted(payload.items())]
    payload['profile-manifest.json'] = json_bytes({
        'format': 'rymcp-official-profile-v2', 'version': manifest['scheme_version'],
        'maintenance_source_manifest_sha256': digest(manifest_raw), 'files': records,
    })
    actual = {path.relative_to(destination).as_posix()
              for path in destination.rglob('*') if path.is_file()
              and '__pycache__' not in path.relative_to(destination).parts} if destination.exists() else set()
    extra = actual - payload.keys()
    different = [relative for relative, raw in payload.items()
                 if relative not in actual or source_path(destination, relative).read_bytes() != raw]
    if check:
        if extra or different:
            raise ValueError(f'Derived official profile differs: extra={sorted(extra)}, changed={different}')
    else:
        if extra:
            previous_path = destination / 'profile-manifest.json'
            previous = json.loads(previous_path.read_bytes()) if previous_path.is_file() else {}
            if previous.get('format') != 'rymcp-official-profile-v2':
                raise ValueError('Cannot retire generated files without their previous source manifest.')
            owned = {row['path']: row for row in previous['files']}
            for relative in sorted(extra):
                path = source_path(destination, relative)
                if relative not in owned or digest(path.read_bytes()) != owned[relative]['sha256']:
                    raise ValueError(f'Unexpected or edited file in the derived official profile: {relative}')
            for relative in sorted(extra):
                source_path(destination, relative).unlink()
        for relative, raw in payload.items():
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
    return {'official_files': len(records), 'checked': check,
            'source_manifest_sha256': digest(manifest_raw)}


def prepare_official(profile, destination):
    if destination.exists():
        raise ValueError('Fresh official profile destination already exists.')
    metadata = json.loads((profile / 'profile-manifest.json').read_bytes())
    destination.mkdir(parents=True)
    seen = set()
    for record in metadata['files']:
        relative = record['path']
        target_name = relative.removeprefix('samples/')
        if target_name in seen:
            raise ValueError(f'Duplicate fresh official path: {target_name}')
        seen.add(target_name)
        raw = source_path(profile, relative).read_bytes()
        if digest(raw) != record['sha256'] or len(raw) != record['bytes']:
            raise ValueError(f'Generated official profile differs: {relative}')
        target = destination / target_name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default=ROOT / 'config/pc', type=Path)
    parser.add_argument('--profiles', default=ROOT / 'config/profiles.json', type=Path)
    parser.add_argument('--output', type=Path)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument('--check', action='store_true', help='Check the tracked official derivation.')
    operation.add_argument('--refresh-official', action='store_true', help='Refresh the tracked official derivation.')
    operation.add_argument('--refresh-source-manifest', action='store_true',
                           help='Inventory reviewed maintained source edits before regenerating profiles.')
    parser.add_argument('--scheme-version', help='Set the dated version when refreshing the source manifest.')
    parser.add_argument('--profile', choices=('all', 'stellae', 'official-weasel'), default='all')
    parser.add_argument('--prepare-official', type=Path)
    args = parser.parse_args()
    if args.refresh_source_manifest:
        if args.output or args.prepare_official or args.source.resolve() != (ROOT / 'config/pc').resolve():
            parser.error('Source inventory refresh only applies to maintained config/pc.')
        print(json.dumps(refresh_source_manifest(args.source, args.scheme_version)))
        return
    if args.scheme_version:
        parser.error('--scheme-version requires --refresh-source-manifest.')
    for destination in (args.output, args.prepare_official):
        if destination and destination.resolve().is_relative_to(args.source.resolve()):
            raise ValueError('Generated profiles must not be written inside the maintained source.')
    manifest, manifest_raw, inputs = load_inputs(args.source)
    check_common_contract(inputs)
    specifications = json.loads(args.profiles.read_bytes())
    if specifications['format'] != 'rymcp-maintained-profiles-v1':
        raise ValueError('Unknown profile specification.')
    if args.check or args.refresh_official:
        if args.output or args.prepare_official or args.source.resolve() != (ROOT / 'config/pc').resolve():
            parser.error('Tracked derivation uses config/pc without output or fresh-profile arguments.')
        print(json.dumps(maintained_official(manifest, manifest_raw, inputs, specifications, args.check)))
        return
    if not args.output:
        parser.error('--output, --check or --refresh-official is required.')
    selected = ('stellae', 'official-weasel') if args.profile == 'all' else (args.profile,)
    report = {'format': 'rymcp-maintained-profile-build-v1',
              'source_manifest_sha256': digest(manifest_raw),
              'profile_specification_sha256': digest(args.profiles.read_bytes()), 'profiles': {}}
    for name in selected:
        specification = specifications['profiles'][name]
        relative = PurePosixPath(specification['output'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid profile output specification.')
        if (args.output / str(relative)).resolve().is_relative_to(args.source.resolve()):
            raise ValueError('A generated profile must not replace maintained source files.')
        payload = adapt_profile(inputs, name, specification)
        report['profiles'][name] = write_profile(args.output / str(relative), payload,
                                                 manifest, digest(manifest_raw), name)
    if args.prepare_official:
        if 'official-weasel' not in selected:
            raise ValueError('--prepare-official requires the official profile.')
        prepare_official(args.output / specifications['profiles']['official-weasel']['output'],
                         args.prepare_official)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'profile-build.json').write_bytes(json_bytes(report))
    print(json.dumps({'profiles': list(selected), 'source_files': len(inputs)}, separators=(',', ':')))


if __name__ == '__main__':
    main()
