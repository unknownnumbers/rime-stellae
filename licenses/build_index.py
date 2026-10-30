# SPDX-License-Identifier: GPL-3.0-only
"""Generate the source-tree license index from explicit upstream notice records."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    mapping = json.loads((ROOT / 'licenses/package-sources.json').read_text('utf-8'))
    originals = json.loads((ROOT / 'licenses/third-party-source-manifest.json').read_text('utf-8'))
    notices = {item['path']: item for item in originals['files']}
    sources = mapping['sources']
    files = []
    for path in sorted(ROOT.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if any(part in {'.git', '__pycache__', 'work', 'out', '.venv', '.pytest_cache'}
               for part in relative.parts):
            continue
        name = relative.as_posix()
        if name in notices:
            record = {'path': name, 'source_ids': [], 'references': [],
                      'notice_record': name}
        else:
            if path.suffix == '.md' or name in {'LICENSE-DOCS'}:
                ids = ['project-docs']
            elif name.startswith('native/weasel/') and name.endswith('.patch'):
                ids = ['project-code', 'weasel', 'native-dependencies']
            elif name.startswith('native/engine/') and name.endswith('.patch'):
                ids = ['project-code', 'librime-lua' if 'lua' in path.name else 'librime']
            else:
                ids = ['project-code']
            references = sorted({notice for key in ids for notice in sources[key]['notices']})
            record = {'path': name, 'source_ids': ids, 'references': references}
        files.append(record)
    index = {
        'format': 'stellae-file-license-index-v1',
        'scope': 'License scope for every file in this source snapshot. Third-party notices retain their original terms. Generated installer payloads have a separate per-file license index.',
        'project_program_license': 'GPL-3.0-only',
        'project_original_documentation_license': 'CC-BY-SA-4.0',
        'sources': sources,
        'files': files,
    }
    # The index describes itself on the first generation as well.
    if not any(item['path'] == 'licenses/file-licenses.json' for item in files):
        files.append({'path': 'licenses/file-licenses.json',
                      'source_ids': ['project-code'], 'references': ['LICENSE']})
        files.sort(key=lambda item: item['path'])
    text = json.dumps(index, ensure_ascii=False, indent=2) + '\n'
    target = ROOT / 'licenses/file-licenses.json'
    for name, notice in notices.items():
        data = (ROOT / name).read_bytes()
        blob = b'blob ' + str(len(data)).encode('ascii') + b'\0' + data
        if len(data) != notice['bytes'] or hashlib.sha256(data).hexdigest() != notice['sha256']:
            raise SystemExit('Upstream notice differs: ' + name)
        if hashlib.sha1(blob).hexdigest() != notice['git_blob_sha1']:
            raise SystemExit('Upstream notice blob differs: ' + name)
    if args.check:
        if target.read_text('utf-8') != text:
            raise SystemExit('License index is stale; run licenses/build_index.py')
    else:
        target.write_text(text, encoding='utf-8', newline='\n')
    print(json.dumps({'source_files': len(files), 'original_notices': len(notices)}))


if __name__ == '__main__':
    main()
