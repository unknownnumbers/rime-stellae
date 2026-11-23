#!/usr/bin/env python3
"""Resolve the two standard OpenCC dictionaries for one local installation.

GPL-3.0-only. Copyright 2026 RymCp contributors.
No source dictionary is copied, modified or downloaded. The output is a local
path-bearing config and should not be committed to the public repository.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def resolve_config(template, shared_dir):
    result = json.loads(template.read_text('utf-8'))
    opencc_dir = shared_dir / 'opencc' if (shared_dir / 'opencc').is_dir() else shared_dir
    expected = {'TSPhrases.ocd2', 'TSCharacters.ocd2'}
    for name in expected:
        if not (opencc_dir / name).is_file():
            raise ValueError(f'Missing standard OpenCC resource: {name}')
    mdx = template.with_name('mdx_words.txt')
    if not mdx.is_file():
        raise ValueError('The template must be next to mdx_words.txt')

    def visit(value):
        if isinstance(value, dict):
            name = value.get('file')
            if name in expected:
                value['file'] = (opencc_dir / name).resolve().as_posix()
            elif name == 'mdx_words.txt':
                value['file'] = mdx.resolve().as_posix()
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared-dir', type=Path, required=True, help='Rime shared data directory, or its opencc subdirectory.')
    parser.add_argument('--template', type=Path, default=Path(__file__).resolve().parents[1] / 'opencc/mdx_t2s.json')
    parser.add_argument('--output', type=Path, required=True, help='New local JSON path; existing files are never overwritten.')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists; choose a new path.')
    try:
        result = resolve_config(args.template, args.shared_dir)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print('Created local OpenCC JSON. Keep this path-bearing output out of version control.')


if __name__ == '__main__':
    main()
