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
    'default.custom.yaml', 'pc_research.custom.yaml', 'jp_sela.schema.yaml', 'rime.lua', 'weasel.custom.yaml',
    'lua/pc_probe_global_mode.lua', 'lua/cn_translator.lua', 'lua/cn_normal_codec.lua',
    'lua/official_translator.lua', 'key_bindings.yaml', 'punctuation.yaml', 'symbols.yaml',
    'opencc/s2t.json', 'opencc/STCharacters.ocd2', 'opencc/STPhrases.ocd2',
    'source-dependencies.json',
}
CTRL_SPACE_LINE = '    - {when: always, accept: Control+space, toggle: ascii_mode}\n'
ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def source_path(root, relative):
    name = PurePosixPath(relative)
    if name.is_absolute() or '..' in name.parts or '\\' in relative:
        raise ValueError(f'Invalid source path: {relative}')
    if name.name in FORBIDDEN_NAMES or any(
        part in FORBIDDEN_PARTS or part.endswith('.userdb') for part in name.parts
    ) or relative.startswith('rymcp_dlc/'):
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
    switch_keys('default.custom.yaml', '    switch_key:\n', pc_keys)
    switch_keys('pc_research.custom.yaml', '  ascii_composer/switch_key:\n', pc_keys)
    switch_keys('jp_sela.schema.yaml', '  switch_key:\n',
                {'Shift_L': 'noop', 'Shift_R': 'inline_ascii', 'Caps_Lock': 'noop'})
    schemas = re.findall(r'^    - schema: (\S+)\s*$', inputs['default.custom.yaml'].decode('utf-8'), re.MULTILINE)
    if schemas != ['pc_research', 'jp_sela']:
        raise ValueError('The shared preset must contain the two maintained schemas.')


def official_pc_settings(text):
    start = text.index('  menu/page_size: 5\n')
    end = text.index('  switches:\n', start)
    block = text[start:end]
    keys = re.findall(r'^  ([^\s][^\n]*?):(?: |$)', block, flags=re.MULTILINE)
    if set(keys) != {'menu/page_size', 'menu/chinese_page_size', 'menu/english_page_size', 'style/mode_layout'}:
        raise ValueError('Unexpected fields inside the reviewed dynamic layout block.')
    text = text[:start] + '  menu/page_size: 6\n' + text[end:]
    text = replace_once(text, '  translator/use_stock_word_completion: false\n',
                        '  translator/use_stock_word_completion: true\n')
    if 'accept: Control+space' in text:
        raise ValueError('PC customization must not own the default Ctrl+Space binding.')
    return replace_once(text,
        '# Public PC baseline: matching patched Weasel and librime-lua builds are required.',
        '# Full scheme for official Weasel with a fixed candidate page.')


def adapt_profile(inputs, name, specification):
    result = dict(inputs)
    if name == 'official-weasel':
        if specification['stock_word_completion'] is not True or specification['ctrl_space_owner'] != 'official-client':
            raise ValueError('Unexpected official capability specification.')
        result['pc_research.custom.yaml'] = edit_text(result['pc_research.custom.yaml'], official_pc_settings)
        result['default.custom.yaml'] = edit_text(result['default.custom.yaml'],
            lambda text: replace_once(text, CTRL_SPACE_LINE, ''))
        style = result['weasel.custom.yaml'].decode('utf-8')
        for setting in ('"style/inline_preedit": false', '"style/horizontal": false'):
            if setting not in style:
                raise ValueError(f'Official default style must retain {setting}.')
    elif name == 'stellae':
        if specification['stock_word_completion'] is not False:
            raise ValueError('Unexpected Stellae capability specification.')
        text = result['pc_research.custom.yaml'].decode('utf-8').replace('\r\n', '\n')
        if text.count('  translator/use_stock_word_completion: false\n') != 1:
            raise ValueError('Stellae source must explicitly select its native completion capability.')
        default = result['default.custom.yaml'].decode('utf-8').replace('\r\n', '\n')
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
              for path in destination.rglob('*') if path.is_file()} if destination.exists() else set()
    extra = actual - payload.keys()
    different = [relative for relative, raw in payload.items()
                 if relative not in actual or source_path(destination, relative).read_bytes() != raw]
    if check:
        if extra or different:
            raise ValueError(f'Derived official profile differs: extra={sorted(extra)}, changed={different}')
    else:
        if extra:
            raise ValueError(f'Unexpected files in the derived official profile: {sorted(extra)}')
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
    parser.add_argument('--profile', choices=('all', 'stellae', 'official-weasel'), default='all')
    parser.add_argument('--prepare-official', type=Path)
    args = parser.parse_args()
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
