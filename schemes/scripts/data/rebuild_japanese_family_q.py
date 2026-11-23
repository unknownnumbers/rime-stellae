# SPDX-License-Identifier: GPL-3.0-only
"""Rebuild Japanese character q codes from public readings and current rules.

Copyright 2026 RymCp contributors.
The algorithm is GPL-3.0-only. Generated readings retain the source-specific
terms recorded in docs/sources/jp-v-sources.md. The inputs are the public
jp_v_chars.lua, japanese-q-canonical.json and jp_family_data.lua; no external
input-method table, network resource or learning database is read.
Only q_codes and its generation comment change. Other family fields are
preserved verbatim. Run with --check to verify the committed generated table.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

import build_japanese_q as spelling


ROOT = Path(__file__).resolve().parents[2]
NOTICE = '-- q_codes generated from jp_v_chars and current canonical rules by scripts/data/rebuild_japanese_family_q.py.\n'
QUOTED = r'"(?:\\.|[^"\\])*"'
CHARACTER_ROW = re.compile(r'^\[(' + QUOTED + r')\]=\{\["readings"\]=(\{[^{}]*\}),')


def character_readings(source):
    """Read the generated literal format without executing Lua source."""
    result = {}
    for number, line in enumerate(source.splitlines(), 1):
        if not line.startswith('['):
            if line and not line.startswith('--') and line not in ('return {', '}'):
                raise ValueError(f'Unexpected character-table syntax at line {number}')
            continue
        match = CHARACTER_ROW.match(line)
        if not match:
            raise ValueError(f'Expected a generated character record at line {number}')
        character = json.loads(match[1])
        readings = json.loads('[' + match[2][1:-1] + ']')
        if len(character) != 1 or character in result or any(not isinstance(x, str) for x in readings):
            raise ValueError(f'Invalid or duplicate character record at line {number}')
        result[character] = readings
    if not result:
        raise ValueError('The public character reading table is empty')
    return result


def q_table_span(source):
    """Locate one final q_codes table, ignoring braces inside quoted strings."""
    marker = ',q_codes='
    if source.count(marker) != 1:
        raise ValueError('Expected exactly one q_codes family field')
    start = source.index(marker) + len(marker)
    if source[start:start + 1] != '{':
        raise ValueError('Expected a literal q_codes table')
    depth, quoted, escaped = 0, False, False
    for position in range(start, len(source)):
        char = source[position]
        if quoted:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                end = position + 1
                if source[end:].strip() != '}':
                    raise ValueError('q_codes must be the final family field')
                return start, end
    raise ValueError('Unterminated q_codes table')


def literal(values):
    return '{' + ','.join(json.dumps(x, ensure_ascii=False) for x in values) + '}'


def rebuild(directory):
    characters_path = directory / 'lua/jp_v_chars.lua'
    canonical_path = directory / 'japanese-q-canonical.json'
    family_path = directory / 'lua/jp_family_data.lua'
    characters = character_readings(characters_path.read_text('utf-8-sig'))
    spelling.KANA_SOURCE = canonical_path
    spelling.INVENTORY = spelling.kana_inventory()
    spelling.TOKENS = sorted(spelling.INVENTORY, key=lambda kana: (-len(kana), kana))
    spelling.romanize.cache_clear()
    codes = {}
    reading_count = 0
    for character, readings in sorted(characters.items()):
        selected = set()
        for reading in readings:
            reading_count += 1
            romanized = spelling.romanize(reading)
            if not romanized:
                raise ValueError(f'Unrepresentable official reading: {character!r} {reading!r}')
            selected.update('q' + code for code in romanized)
        if selected:
            codes[character] = sorted(selected)
    table = '{' + ','.join('[' + json.dumps(character, ensure_ascii=False) + ']=' + literal(values)
                           for character, values in codes.items()) + '}'
    source = family_path.read_text('utf-8-sig')
    start, end = q_table_span(source)
    # Never retain or consult the old q table's character/code contents.
    rebuilt = source[:start] + table + source[end:]
    if NOTICE not in rebuilt:
        return_at = rebuilt.index('return {')
        rebuilt = rebuilt[:return_at] + NOTICE + rebuilt[return_at:]
    report = {
        'format': 'rymcp-japanese-family-q-v1',
        'character_records': len(characters),
        'official_readings': reading_count,
        'q_characters': len(codes),
        'q_codes': sum(map(len, codes.values())),
        'sources': {
            'lua/jp_v_chars.lua': hashlib.sha256(characters_path.read_bytes()).hexdigest(),
            'japanese-q-canonical.json': hashlib.sha256(canonical_path.read_bytes()).hexdigest(),
            'scripts/data/build_japanese_q.py': hashlib.sha256(Path(spelling.__file__).read_bytes()).hexdigest(),
        },
        'retained_family_fields_sha256': hashlib.sha256((source[:start].replace(NOTICE, '') + source[end:]).encode('utf-8')).hexdigest(),
        'output_sha256': hashlib.sha256(rebuilt.encode('utf-8')).hexdigest(),
        'examples': {key: codes.get(key, []) for key in ('一', '上', '日', '本', '桜', '櫻', '痔')},
    }
    return rebuilt, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'config/pc')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true', help='Verify committed q codes without writing files')
    mode.add_argument('--output', type=Path, help='New output file; existing files are never overwritten')
    args = parser.parse_args()
    rebuilt, report = rebuild(args.directory)
    if args.check:
        if (args.directory / 'lua/jp_family_data.lua').read_bytes() != rebuilt.encode('utf-8'):
            parser.error('Committed family q codes differ from public readings and current rules')
        report['status'] = 'verified'
    else:
        if args.output.exists():
            parser.error('Output already exists; choose a new file')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('xb') as output:
            output.write(rebuilt.encode('utf-8'))
        report['status'] = 'generated'
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))


if __name__ == '__main__':
    main()
