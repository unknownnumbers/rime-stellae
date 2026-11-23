#!/usr/bin/env python3
"""Validate independently specified Japanese behavior without a legacy table.

GPL-3.0-only. Copyright 2026 RymCp contributors.
This checks public phonetic fixtures and generated-file consistency. It does
not run Rime, read learning databases or claim native candidate-order parity.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def load_generator():
    path = Path(__file__).with_name('generate-japanese-base.py')
    spec = importlib.util.spec_from_file_location('rymcp_japanese_base', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def romanize(reading, inventory):
    # Fixture oracle for the public q-code format, separate from generation.
    tokens = sorted(inventory, key=lambda value: (-len(value), value))
    code, position = '', 0
    while position < len(reading):
        if reading[position] == 'ん':
            following = reading[position + 1:position + 2]
            code += "n'" if following and following in 'あいうえおやゆよ' else 'n'
            position += 1
            continue
        token = next((item for item in tokens if reading.startswith(item, position)), None)
        if token is None:
            return ()
        code += inventory[token]
        position += len(token)
    return (code, code + 'n') if code.endswith('n') else (code,)


def validate(directory=None):
    generator = load_generator()
    inventory = generator.build_inventory()
    rows = generator.dictionary_rows()
    by_code = {}
    for text, code in rows:
        by_code.setdefault(code, set()).add(text)
    checks = 0

    def check(condition, message):
        nonlocal checks
        if not condition:
            raise AssertionError(message)
        checks += 1

    for code, expected in (
        ('a', 'あ'), ('A', 'ア'), ('shi', 'し'), ('SHI', 'シ'),
        ('chi', 'ち'), ('tsu', 'つ'), ('fu', 'ふ'), ('di', 'ぢ'),
        ('di', 'でぃ'), ('dsu', 'づ'), ('wi', 'ゐ'), ('WE', 'ヱ'),
        ('si', 'すぃ'), ('SI', 'スィ'), ('ti', 'てぃ'), ('TU', 'トゥ'),
        ('xa', 'ぁ'), ('XA', 'ァ'), ('xtsu', 'っ'), ('XTSU', 'ッ'),
        ('xka', 'ゕ'), ('XKE', 'ヶ'), ('kya', 'きゃ'), ('KYO', 'キョ'),
        ('gye', 'ぎぇ'), ('kwu', None), ('kwi', 'くぃ'),
        ('vye', 'ゔぃぇ'), ('FYE', 'フィェ'), ('l', 'ー'), ('L', 'ー'),
        ('-', 'ー'), ('nn', 'ん'), ('NN', 'ン'), ('nnya', 'んにゃ'),
        ('NNYE', 'ンニェ'), ('cchi', 'っち'), ('ssha', 'っしゃ'),
        ('ffu', 'っふ'), ('yya', 'っや'),
    ):
        if expected is None:
            check(code not in by_code, f'Unspecified alias admitted: {code}')
        else:
            check(expected in by_code.get(code, set()), f'{code} must offer {expected}')
    for reading, expected in (
        ('たべる', ('taberu',)), ('しんや', ("shin'ya",)),
        ('にんにゃ', ('ninnya',)), ('かん', ('kan', 'kann')),
        ('こっちゃ', ('koccha',)), ('がっこう', ('gakkou',)),
        ('きょう', ('kyou',)), ('ぢ', ('di',)), ('づ', ('dsu',)),
        ('ゐ', ('wi',)), ('ゑ', ('we',)), ('うー', ('wu',)),
        ('すぃ', ('si',)), ('ー', ('l',)), ('😀', ()),
    ):
        check(romanize(reading, inventory) == expected, f'Unexpected q code for {reading}')
    check(len(inventory) == 322, 'Canonical segment boundary changed')
    check(len(rows) == len(set(rows)), 'Duplicate dictionary rows')
    check(all(code.isascii() and (code.isalpha() or code == '-') for _, code in rows), 'Unexpected code alphabet')
    check(not any('\u3400' <= c <= '\u9fff' for text, _ in rows for c in text if text != '々'), 'Borrowed Han rows are forbidden')
    check('っな' not in inventory and 'っゔ' not in inventory, 'Unsupported sokuon rule widened')
    check('うぃ' not in inventory and 'うぇ' not in inventory, 'Archaic wi/we policy changed')
    check('si' not in {inventory.get('し')} and inventory['し'] == 'shi', 'Ordinary shi changed')

    outputs = generator.render_outputs()
    if directory is not None:
        for name, content in outputs.items():
            check((directory / name).read_bytes() == content.encode('utf-8'), f'Stale generated file: {name}')
    normalized = json.dumps(inventory, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return {
        'checks_passed': checks,
        'canonical_segments': len(inventory),
        'dictionary_rows': len(rows),
        'canonical_mapping_sha256': hashlib.sha256(normalized).hexdigest(),
        'legacy_input_required': False,
        'native_engine_validation': 'not covered by this script',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, help='Optionally verify generated files in this config directory.')
    args = parser.parse_args()
    print(json.dumps(validate(args.directory), ensure_ascii=True, indent=2))


if __name__ == '__main__':
    main()
