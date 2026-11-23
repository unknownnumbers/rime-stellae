"""Refresh source-file license coverage without replacing source-specific terms.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations

import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / 'licenses/file-licenses.json'
IGNORED = {'.git', '__pycache__', 'out', 'work', '.venv', '.pytest_cache'}
ORIGINAL_PROSE = {
    'kind': 'project-explanatory-document',
    'project_license': 'CC-BY-SA-4.0',
    'license_scope': 'Original explanatory prose; quotations, attribution statements and code/data excerpts retain their own terms.',
    'references': ['THIRD_PARTY_NOTICES.md', 'licenses/CC-BY-SA-4.0.txt'],
}
ORIGINAL_PROGRAM = {
    'kind': 'program-or-configuration',
    'project_license': 'GPL-3.0-only',
    'license_scope': 'Original project additions and modifications; retained upstream expression keeps its original terms.',
    'retained_upstream_terms': [],
    'references': ['LICENSE'],
}


def upstream_configuration(path: str) -> dict | None:
    if path in {'config/pc/opencc/TSCharacters.ocd2', 'config/pc/opencc/TSPhrases.ocd2',
                'config/pc/opencc/STCharacters.ocd2', 'config/pc/opencc/STPhrases.ocd2',
                'config/pc/opencc/s2t.json'}:
        return {
            'kind': 'program-or-configuration' if path.endswith('.json') else 'data-or-generated-data',
            'source_group': 'opencc-conversion-data',
            'source_ids': ['opencc_weasel'],
            'license_scope': 'Unmodified OpenCC conversion data, Apache-2.0; source attribution and notice retained.',
            'references': ['licenses/OpenCC-LICENSE.txt', 'docs/sources/shared-config-sources.md'],
        }
    if path in {'config/pc/default.yaml', 'config/pc/key_bindings.yaml',
                'config/pc/punctuation.yaml', 'config/pc/symbols.yaml'}:
        return {
            'kind': 'program-or-configuration',
            'source_ids': ['prelude'],
            'retained_upstream_terms': ['LGPL-3.0', 'rime-prelude AUTHORS'],
            'license_scope': 'Unmodified upstream default configuration under LGPL-3.0; original attribution retained.',
            'references': ['LICENSE', 'licenses/shared-config/prelude-LICENSE.txt', 'licenses/shared-config/prelude-AUTHORS.txt', 'docs/sources/shared-config-sources.md'],
        }
    if path == 'config/pc/pinyin.yaml':
        return {
            'kind': 'program-or-configuration',
            'source_ids': ['luna_config'],
            'retained_upstream_terms': ['LGPL-3.0'],
            'license_scope': 'Unmodified upstream Pinyin configuration under LGPL-3.0; original source comments retained.',
            'references': ['LICENSE', 'licenses/luna-pinyin-LGPL-3.0.txt', 'docs/sources/shared-config-sources.md'],
        }
    if path in {'config/pc/stroke.schema.yaml', 'config/pc/stroke.dict.yaml'}:
        return {
            'kind': 'data-or-generated-data' if path.endswith('.dict.yaml') else 'program-or-configuration',
            'source_ids': ['stroke'],
            'retained_upstream_terms': ['LGPL-3.0', 'CNS11643 and original AUTHORS attribution'],
            'license_scope': 'Unmodified upstream stroke configuration/data under LGPL-3.0; original CNS11643 and supplementary-table attribution retained.',
            'references': ['LICENSE', 'licenses/radical-stroke/stroke-LGPL-3.0.txt', 'licenses/radical-stroke/stroke-AUTHORS', 'docs/sources/shared-config-sources.md'],
        }
    return None


def official_record(path: str, old: dict[str, dict]) -> dict:
    relative = path.removeprefix('config/official-weasel/')
    if relative.startswith('samples/'):
        relative = relative.removeprefix('samples/')
    base = old.get('config/pc/' + relative)
    if base:
        record = copy.deepcopy(base)
        record['references'] = list(dict.fromkeys(
            record.get('references', []) + ['docs/sources/official-weasel-sources.md']))
        return record
    if relative in {'opencc/TSCharacters.ocd2', 'opencc/TSPhrases.ocd2'}:
        return {
            'kind': 'data-or-generated-data',
            'source_group': 'opencc-conversion-data',
            'source_ids': ['opencc_weasel'],
            'license_scope': 'Unmodified OpenCC conversion data, Apache-2.0; source attribution and notice retained.',
            'references': ['licenses/OpenCC-LICENSE.txt', 'docs/sources/official-weasel-sources.md'],
        }
    if relative in {'lua/official_backup_mode.lua', 'lua/en_distance.lua'}:
        record = copy.deepcopy(ORIGINAL_PROGRAM)
        record['references'].append('docs/sources/official-weasel-sources.md')
        return record
    if relative == 'profile-manifest.json':
        return {
            'kind': 'project-metadata',
            'project_license': 'GPL-3.0-only',
            'license_scope': 'Original structured source and file metadata; referenced source data retains its own terms.',
            'references': ['LICENSE', 'docs/sources/official-weasel-sources.md'],
        }
    raise SystemExit(f'Unreviewed official-profile source: {path}')


def classify(path: str, old: dict[str, dict]) -> dict:
    if path in {
        'config/pc/assets/status/generate.py',
        'config/pc/assets/status/smart-english.svg',
        'config/pc/assets/status/smart-english.ico',
    }:
        record = copy.deepcopy(ORIGINAL_PROGRAM)
        record['kind'] = 'original-status-asset-or-generator'
        return record
    upstream = upstream_configuration(path)
    if upstream:
        return upstream
    if path.startswith('config/official-weasel/'):
        return official_record(path, old)
    if path in old:
        return copy.deepcopy(old[path])
    if path == 'config/pc/lua/scheme_data.lua':
        return copy.deepcopy(ORIGINAL_PROGRAM)
    if path in {'config/profiles.json', 'config/pc/source-dependencies.json'}:
        return {
            'kind': 'project-metadata',
            'project_license': 'GPL-3.0-only',
            'license_scope': 'Original profile and dependency metadata; referenced resources retain their component terms.',
            'references': ['LICENSE', 'docs/sources/shared-config-sources.md'],
        }
    notice = path.removeprefix('config/pc/')
    if notice in {'licenses/shared-config/prelude-LICENSE.txt', 'licenses/shared-config/prelude-AUTHORS.txt'}:
        return {
            'kind': 'retained-upstream-notice',
            'notice_record': notice,
            'source_ids': ['prelude'],
            'license_scope': 'Original upstream license or attribution text, preserved verbatim under its own terms.',
            'references': ['THIRD_PARTY_NOTICES.md', 'licenses/third-party-source-manifest.json'],
        }
    suffix = Path(path).suffix
    if suffix == '.md' and not path.startswith('licenses/'):
        return copy.deepcopy(ORIGINAL_PROSE)
    if path == 'licenses/build_index.py' or path.startswith(('scripts/', 'tests/', '.github/')):
        if suffix in {'.py', '.ps1', '.cs', '.lua', '.json', '.yaml', '.yml'}:
            return copy.deepcopy(ORIGINAL_PROGRAM)
    raise SystemExit(f'Unreviewed source-file license: {path}')


def main() -> None:
    index = json.loads(INDEX.read_text(encoding='utf-8'))
    index['sources']['luna_config'] = {
        'origin': 'rime/rime-luna-pinyin, official Weasel 0.17.4 data/pinyin.yaml',
        'upstream_commit': None,
        'retained_terms': ['GNU LGPL version 3', 'original source comments and reference link'],
        'notices': ['licenses/luna-pinyin-LGPL-3.0.txt', 'LICENSE'],
        'evidence': ['docs/sources/shared-config-sources.md'],
        'caveat': 'The precise upstream configuration commit packaged by Weasel is unknown. The packaged source bytes are pinned by content hash.',
    }
    index['sources']['prelude'] = {
        'origin': 'rime/rime-prelude, official Weasel 0.17.4 packaged default, key bindings, punctuation and symbols',
        'upstream_commit': None,
        'notice_commit': '95542a274915ba5496ff3260a2c71946238d4cce',
        'retained_terms': ['GNU LGPL version 3', 'rime-prelude AUTHORS attribution'],
        'notices': ['licenses/shared-config/prelude-LICENSE.txt', 'licenses/shared-config/prelude-AUTHORS.txt', 'LICENSE'],
        'evidence': ['docs/sources/shared-config-sources.md'],
        'caveat': 'The notice snapshot is pinned separately. The precise historical prelude commit packaged by Weasel is unknown; the resource bytes are pinned by content hash.',
    }
    index['sources']['opencc_weasel'] = {
        'origin': 'BYVoid/OpenCC conversion resources, official Weasel 0.17.4 data/opencc',
        'source_paths': ['TSCharacters.ocd2', 'TSPhrases.ocd2', 'STCharacters.ocd2', 'STPhrases.ocd2', 's2t.json'],
        'upstream_commit': None,
        'retained_terms': ['Apache License 2.0', 'original OpenCC authors'],
        'notices': ['licenses/OpenCC-LICENSE.txt'],
        'evidence': ['docs/sources/official-weasel-sources.md'],
        'caveat': 'The precise OpenCC data commit used for these packaged binaries is unknown; profile-manifest.json pins their bytes.',
    }
    index['sources']['opencc']['caveat'] = (
        'The JP master snapshot has a recorded content hash but no exact upstream commit established. '
        'Standard conversions shipped with the official profile are indexed separately as opencc_weasel.')
    old = {record['path']: record for record in index['files']}
    paths = []
    for file in sorted(ROOT.rglob('*')):
        if not file.is_file() or any(part in IGNORED for part in file.relative_to(ROOT).parts):
            continue
        path = file.relative_to(ROOT).as_posix()
        paths.append(path)
    # Classify common inputs first so new official copies inherit their terms.
    reviewed = dict(old)
    for path in paths:
        if not path.startswith('config/official-weasel/'):
            reviewed[path] = classify(path, old)
    records = []
    for path in paths:
        record = official_record(path, reviewed) if path.startswith('config/official-weasel/') else reviewed[path]
        record['path'] = path
        records.append(record)
    index['files'] = records
    INDEX.write_text(json.dumps(index, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps({'licensedFiles': len(records)}))


if __name__ == '__main__':
    main()
