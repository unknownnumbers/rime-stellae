# SPDX-License-Identifier: GPL-3.0-only
"""Prepare an English DLC index from its existing catalog at packaging time."""
import argparse
from pathlib import Path
import re
from tempfile import TemporaryDirectory
import zlib

if __package__:
    from .build_english_index import write_index
else:
    from build_english_index import write_index


INDEX_FILES = ('words.txt', 'keys.bin', 'postings.bin')
ALIAS = re.compile(r"[a-z][a-z'\-]*\Z", re.ASCII)


def build_dlc_index(catalog, output):
    lines = catalog.decode('utf-8').split('\n')
    if lines[0].removesuffix('\r') != 'format\t1' or lines[-1] != '':
        raise ValueError('Expected a version 1 English DLC catalog')
    aliases = set()
    for line in lines[1:-1]:
        fields = line.removesuffix('\r').split('\t')
        if len(fields) != 9 or fields[0] not in ('word', 'alias') or not ALIAS.fullmatch(fields[1]):
            raise ValueError('Invalid alias row in English DLC catalog')
        aliases.add(fields[1])
    if not aliases:
        raise ValueError('No aliases to index')
    return write_index(sorted(aliases), output)


def add_module_index(files):
    """Return a catalog with its prepared files and extended manifest."""
    with TemporaryDirectory(prefix='rymcp-english-index-') as temp:
        index_dir = Path(temp) / 'index'
        report = build_dlc_index(files['english.tsv'], index_dir)
        additions = {f'english_index/{name}': (index_dir / name).read_bytes() for name in INDEX_FILES}
    manifest = files['manifest.tsv']
    if not manifest.endswith(b'\n'):
        raise ValueError('Malformed DLC module manifest')
    manifest += b''.join(
        f'file\t{name}\t{len(data)}\t{zlib.adler32(data):08x}\n'.encode('ascii')
        for name, data in sorted(additions.items())
    )
    return files | additions | {'manifest.tsv': manifest}, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('catalog', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        raise ValueError('Use a fresh directory for the prepared index')
    report = build_dlc_index(args.catalog.read_bytes(), args.out)
    print(f"Prepared {report['word_count']} English DLC aliases")


if __name__ == '__main__':
    main()
