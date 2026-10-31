"""Render installed documentation with links to its original repository paths."""
# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
from urllib.parse import quote, unquote, urlsplit, urlunsplit


REPOSITORY_URL = 'https://github.com/unknownnumbers/rime-stellae'
LINK = re.compile(r'(?P<start>!?\[[^\]\n]*\]\(\s*)(?P<target><[^>\n]+>|[^\s)]+)(?P<end>(?:[ \t]+["\'][^\n)]*["\'])?\s*\))')
INLINE_CODE = re.compile(r'(`+)(.*?)\1', re.DOTALL)
FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})')


def render(text: str, origin: str, repository: Path, ref: str) -> tuple[str, int]:
    converted = 0

    def replace(match):
        nonlocal converted
        target = match['target']
        angle = target.startswith('<')
        target = target[1:-1] if angle else target
        split = urlsplit(target)
        if split.scheme or split.netloc:
            return match[0]
        if split.path:
            path = split.path.lstrip('/') if split.path.startswith('/') else posixpath.join(posixpath.dirname(origin), split.path)
            path = posixpath.normpath(unquote(path))
        else:
            path = origin
        if path == '..' or path.startswith('../'):
            raise ValueError(f'Link escapes the repository: {origin}: {target}')
        resolved = (repository / PurePosixPath(path)).resolve()
        if not resolved.is_relative_to(repository) or not resolved.exists():
            raise ValueError(f'Missing repository link: {origin}: {target}')
        kind = 'tree' if resolved.is_dir() else 'blob'
        url = f'{REPOSITORY_URL}/{kind}/{quote(ref, safe="")}/{quote(path, safe="/")}'
        split_url = urlsplit(url)
        url = urlunsplit((split_url.scheme, split_url.netloc, split_url.path, split.query, split.fragment))
        converted += 1
        return match['start'] + ('<' + url + '>' if angle else url) + match['end']

    def prose(line):
        # Inline code and fenced examples remain exact.
        result = []
        start = 0
        for code in INLINE_CODE.finditer(line):
            result.append(LINK.sub(replace, line[start:code.start()]))
            result.append(code[0])
            start = code.end()
        result.append(LINK.sub(replace, line[start:]))
        return ''.join(result)

    result = []
    fence = None
    for line in text.splitlines(keepends=True):
        marker = FENCE.match(line)
        if marker:
            run = marker[1]
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = None
            result.append(line)
        else:
            result.append(line if fence else prose(line))
    return ''.join(result), converted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--output-directory', required=True)
    parser.add_argument('--ref', default='main')
    args = parser.parse_args()
    if not args.ref or not re.fullmatch(r'[A-Za-z0-9._/-]+', args.ref) or '..' in args.ref.split('/'):
        raise SystemExit('Invalid repository source ref.')
    repository = Path(args.repository).resolve()
    output = Path(args.output_directory)
    output.mkdir(parents=True, exist_ok=True)
    reports = []

    def document(origin):
        original = (repository / origin).read_bytes().decode('utf-8-sig')
        result, count = render(original, origin, repository, args.ref)
        reports.append({'source': origin, 'relative_links_converted': count})
        return result

    manual = [document(name) for name in ['README.md', 'README.en.md', 'README.zh-SC.md']]
    (output / 'README.txt').write_bytes(('\n\n---\n\n'.join(manual)).encode('utf-8'))
    (output / 'SOURCES.md').write_bytes(document('docs/SOURCES.md').encode('utf-8'))
    (output / 'THIRD_PARTY_NOTICES.md').write_bytes(document('THIRD_PARTY_NOTICES.md').encode('utf-8'))
    print(json.dumps({'ref': args.ref, 'documents': reports}))


if __name__ == '__main__':
    main()
