"""Build a prefix-delete recall index; only Python's standard library is used."""
import argparse
import json
import re
import struct
from pathlib import Path

PREFIX_LENGTH = 7
MAX_DISTANCE = 2
KEY_WIDTH = 8
RECORD = struct.Struct('<8sII')
WORD_ID = struct.Struct('<I')
WORD = re.compile(r"[a-z]+(?:['-][a-z]+)*\Z", re.ASCII)


def deletion_keys(word, budget=MAX_DISTANCE):
    """All unique <= budget deletions of the first seven ASCII characters."""
    prefix = word[:PREFIX_LENGTH]
    seen = {prefix}
    frontier = {prefix}
    for _ in range(budget):
        following = set()
        for value in frontier:
            for i in range(len(value)):
                key = value[:i] + value[i + 1:]
                if key not in seen:
                    seen.add(key)
                    following.add(key)
        frontier = following
    return seen


def read_words(path):
    """Read plain/TSV first-column words or a simple Rime dictionary body."""
    lines = path.read_text(encoding='utf-8-sig').splitlines()
    is_rime = path.name.endswith(('.dict.yaml', '.dict.yml'))
    in_entries = not is_rime
    words = set()
    rows = rejected = 0
    for line in lines:
        if is_rime and not in_entries:
            if line.strip() == '...':
                in_entries = True
            continue
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        rows += 1
        word = line.split('\t', 1)[0].strip().lower()
        if WORD.fullmatch(word):
            words.add(word)
        else:
            rejected += 1
    if not words:
        raise ValueError('No ASCII words in input; expected words/TSV or a Rime dictionary body')
    return sorted(words), {'input_rows': rows, 'rejected_rows': rejected}


def write_index(words, output_dir):
    """Write the native index for ordered, unique ASCII words."""
    postings = {}
    for word_id, word in enumerate(words, 1):
        for key in deletion_keys(word):
            postings.setdefault(key, []).append(word_id)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / 'words.txt').write_text(''.join(word + '\n' for word in words),
                                         encoding='ascii', newline='\n')
    posting_count = 0
    with (output_dir / 'keys.bin').open('wb') as keys_file, \
            (output_dir / 'postings.bin').open('wb') as postings_file:
        for key in sorted(postings):
            ids = postings[key]
            keys_file.write(RECORD.pack(key.encode('ascii').ljust(KEY_WIDTH, b'\0'),
                                        posting_count * WORD_ID.size, len(ids)))
            for word_id in ids:
                postings_file.write(WORD_ID.pack(word_id))
            posting_count += len(ids)

    return {
        'format': 'ascii-prefix-delete-v1',
        'prefix_length': PREFIX_LENGTH,
        'max_distance': MAX_DISTANCE,
        'record_bytes': RECORD.size,
        'word_count': len(words),
        'key_count': len(postings),
        'posting_count': posting_count,
        'largest_posting': max(map(len, postings.values())),
        'bytes': {name: (output_dir / name).stat().st_size
                  for name in ('words.txt', 'keys.bin', 'postings.bin')},
    }


def build(input_path, output_dir):
    words, report = read_words(input_path)
    report.update(write_index(words, output_dir))
    (output_dir / 'build-report.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Plain words, TSV first column, or .dict.yaml')
    parser.add_argument('--out', type=Path, required=True, help='Directory for generated resources')
    args = parser.parse_args()
    print(json.dumps(build(args.input, args.out), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
