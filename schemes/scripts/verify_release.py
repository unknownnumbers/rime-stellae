"""Verify the committed source snapshot, portable paths and configuration syntax.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '__pycache__', 'out', 'work', '.venv', '.pytest_cache'}
MANIFEST = ROOT / 'release-manifest.json'


def files():
    return sorted((p for p in ROOT.rglob('*') if p.is_file()
                   and not any(part in IGNORED for part in p.relative_to(ROOT).parts)
                   and not p.relative_to(ROOT).as_posix().startswith('dlc/archives/')),
                  key=lambda p: p.relative_to(ROOT).as_posix())


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def source_archive_members(path, relative):
    """Inspect bounded archive metadata without decoding the corpus again."""
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if not members or len(members) > 5000 or sum(item.file_size for item in members) > 250_000_000:
            raise SystemExit(f'Unexpected fixed source archive size: {relative}')
        seen = set()
        for item in members:
            name = item.filename
            parts = name.split('/')
            mode = stat.S_IFMT(item.external_attr >> 16)
            if (not name or name != item.orig_filename or name in seen
                    or any(part in ('', '.', '..') for part in parts)
                    or '\\' in name or ':' in name or '\x00' in name
                    or PurePosixPath(name).is_absolute() or item.is_dir()
                    or mode not in (0, stat.S_IFREG) or item.flag_bits & 1):
                raise SystemExit(f'Invalid source archive member in {relative}: {name}')
            seen.add(name)
            suffix = PurePosixPath(name).suffix.lower()
            if relative.startswith('poetry/'):
                allowed = name == 'LICENSE' or suffix == '.json'
                if relative == 'poetry/companion-anthologies.zip':
                    allowed = allowed or suffix == '.md'
            elif relative == 'readings/pypinyin-0.55.0-py2.py3-none-any.whl':
                allowed = (parts[0] in ('pypinyin', 'pypinyin-0.55.0.dist-info')
                           and (suffix in ('.py', '.pyi', '.json', '.typed', '.txt')
                                or PurePosixPath(name).name in ('METADATA', 'WHEEL', 'RECORD', 'LICENSE')))
            elif relative == 'readings/Unihan-17.0.0.zip':
                allowed = re.fullmatch(r'Unihan_[A-Za-z]+\.txt', name) is not None
            elif re.fullmatch(r'science/science-api-responses-\d{3}\.zip', relative):
                allowed = (name == 'requests.json' or re.fullmatch(
                    r'source-cache/(?:enwiki|enwiki-main|wikidata)/[0-9a-f]{64}\.json\.gz', name) is not None)
            else:
                allowed = False
            if not allowed:
                raise SystemExit(f'Unexpected source archive member type in {relative}: {name}')


def verify_catalog_sources():
    """Only exact locked source archives qualify for binary text-scan skips."""
    root = ROOT / 'dlc/sources'
    lock = json.loads((root / 'catalog-source-lock.json').read_text(encoding='utf-8'))
    if lock.get('Format') != 1 or not isinstance(lock.get('Files'), list) or not lock['Files']:
        raise SystemExit('Invalid fixed catalog source lock')
    checked, archives = set(), set()
    for record in lock['Files']:
        relative = record['Path']
        if (not isinstance(relative, str) or not relative
                or any(part in ('', '.', '..') for part in relative.split('/'))
                or '\\' in relative or ':' in relative or '\x00' in relative
                or PurePosixPath(relative).is_absolute() or relative in checked):
            raise SystemExit('Invalid or repeated fixed catalog source path')
        path = root / relative
        if (path.is_symlink() or not path.resolve().is_relative_to(root.resolve())
                or not path.is_file() or path.stat().st_size != record['Bytes']
                or digest(path) != record['Sha256']):
            raise SystemExit(f'Fixed catalog source differs from its checksum lock: {relative}')
        checked.add(relative)
        if path.suffix.lower() in ('.zip', '.whl'):
            source_archive_members(path, relative)
            archives.add(path.resolve())
    return len(checked), archives


def verify_licenses(payload):
    """Check license coverage, source links and retained original notice bytes."""
    index = json.loads((ROOT / 'licenses/file-licenses.json').read_text(encoding='utf-8'))
    records = index['files']
    actual = {p.relative_to(ROOT).as_posix() for p in payload}
    declared = [record['path'] for record in records]
    if len(declared) != len(set(declared)) or set(declared) != actual:
        missing = sorted(actual - set(declared))
        stale = sorted(set(declared) - actual)
        raise SystemExit(f'License index coverage differs: missing={missing}, stale={stale}')

    def require_file(name):
        path = ROOT / name
        if not path.resolve().is_relative_to(ROOT.resolve()) or not path.is_file():
            raise SystemExit(f'Missing or invalid license reference: {name}')
        return path

    sources = index['sources']
    for source in sources.values():
        for name in source.get('notices', []) + source.get('evidence', []):
            require_file(name)
    manifest = json.loads((ROOT / 'licenses/third-party-source-manifest.json').read_text(encoding='utf-8'))
    originals = {record['path']: record for record in manifest['files']}
    for name, record in originals.items():
        path = require_file(name)
        raw = path.read_bytes()
        if len(raw) != record['bytes'] or digest(path) != record['sha256']:
            raise SystemExit(f'Retained upstream notice differs: {name}')
        blob = b'blob ' + str(len(raw)).encode('ascii') + b'\0' + raw
        if hashlib.sha1(blob).hexdigest() != record['git_blob_sha1']:
            raise SystemExit(f'Retained upstream notice Git blob differs: {name}')
    for record in records:
        for name in record.get('references', []):
            require_file(name)
        for name in record.get('source_ids', []):
            if name not in sources:
                raise SystemExit(f'Unknown license source in {record["path"]}: {name}')
        if 'notice_record' in record:
            original = originals.get(record['notice_record'])
            if not original or digest(ROOT / record['path']) != original['sha256']:
                raise SystemExit(f'Upstream notice copy differs: {record["path"]}')
    return len(records), len(originals)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-manifest', action='store_true', help='Record a new reviewed source snapshot before committing')
    parser.add_argument('--require-yaml', action='store_true', help='Require PyYAML for YAML syntax checks')
    args = parser.parse_args()
    payload = files()
    catalog_source_count, locked_archives = verify_catalog_sources()
    forbidden_extensions = {'.dll', '.exe', '.pdb', '.dmp', '.log', '.userdb'}
    for path in payload:
        if path.is_symlink() or path.suffix.lower() in forbidden_extensions or '.userdb' in path.name:
            raise SystemExit(f'Unexpected runtime or personal file: {path.relative_to(ROOT)}')
        if path.suffix.lower() in ('.zip', '.whl') and path.resolve() not in locked_archives:
            raise SystemExit(f'Unlocked source archive: {path.relative_to(ROOT)}')
        if path.stat().st_size >= 100_000_000:
            raise SystemExit(f'File exceeds this source snapshot size limit: {path.relative_to(ROOT)}')
    private_marker = re.compile(
        r'(?i)(?:[a-z]:[\\/](?:Users|Portable)[\\/]|' + '/' + 'Users' + r'/[^/\s]+/|'
        + '/' + 'home' + r'/[^/\s]+/|'
        r'gh[pousr]_[a-z0-9]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)'
    )
    python_count = json_count = yaml_count = 0
    try:
        import yaml
    except ImportError:
        yaml = None
        if args.require_yaml:
            raise SystemExit('Install PyYAML to perform required YAML syntax checks')
    for path in payload:
        if path.resolve() in locked_archives:
            continue
        if path.suffix == '.ico':
            if path.relative_to(ROOT).as_posix() not in {'config/pc/assets/status/smart-english.ico',
                                                          'config/official-weasel/assets/status/smart-english.ico'}:
                raise SystemExit('Unexpected status icon resource')
            data = path.read_bytes()
            if len(data) < 6 or struct.unpack_from('<HHH', data) != (0, 1, 8):
                raise SystemExit('Invalid En status icon container')
            continue
        if path.suffix in {'.bin', '.gram', '.ocd2', '.gz', '.xz'}:
            continue
        try:
            source = path.read_text(encoding='utf-8-sig')
        except UnicodeDecodeError:
            # Original third-party HTML notices can use a declared legacy encoding.
            if path.suffix.lower() not in {'.html', '.htm'}:
                raise SystemExit(f'Unexpected non-text source: {path.relative_to(ROOT)}')
            continue
        if private_marker.search(source):
            raise SystemExit(f'Personal path or credential marker in {path.relative_to(ROOT)}')
        if path.suffix == '.py':
            ast.parse(source, filename=str(path.relative_to(ROOT)))
            python_count += 1
        elif path.suffix == '.json':
            json.loads(source)
            json_count += 1
        elif path.suffix in {'.yaml', '.yml'} and yaml is not None:
            header = source.split('\n...\n', 1)[0] if '.dict.' in path.name else source
            yaml.safe_load(header)
            yaml_count += 1
        # Preserve upstream notices verbatim, including links relative to their
        # original repositories. Validate links in authored project documents.
        relative = path.relative_to(ROOT)
        if path.suffix == '.md' and relative.parts[0] != 'licenses':
            for target in re.findall(r'(?<!!)\[[^\]]*\]\(([^)]+)\)', source):
                if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target) or target.startswith('#'):
                    continue
                target = target.split('#', 1)[0]
                if target and not (path.parent / target).exists():
                    raise SystemExit(f'Missing link in {path.relative_to(ROOT)}: {target}')
    licensed_count, notice_count = verify_licenses(payload)
    records = [{
        'path': path.relative_to(ROOT).as_posix(),
        'bytes': path.stat().st_size,
        'sha256': digest(path),
    } for path in payload if path != MANIFEST]
    if args.write_manifest:
        manifest = {
            'format': 'stellae-schemes-source-v1',
            'date': '2026-11-24',
            'kind': 'source-configuration-data-snapshot',
            'nativeBinariesIncluded': False,
            'personalLearningIncluded': False,
            'independentJapaneseBase': True,
            'upstreamGenerationLimits': 'See docs/sources/README.md; fixed snapshots do not establish complete historical corpus regeneration.',
            'files': records,
        }
        MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    else:
        manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
        expected = {record['path']: record for record in manifest['files']}
        actual = {record['path']: record for record in records}
        if expected != actual:
            changed = sorted(name for name in expected.keys() | actual.keys()
                             if expected.get(name) != actual.get(name))
            raise SystemExit('Source snapshot differs from release-manifest.json: '
                             + ', '.join(changed[:10]))
    print(json.dumps({
        'verifiedFiles': len(records), 'pythonParsed': python_count,
        'jsonParsed': json_count, 'yamlParsed': yaml_count,
        'yamlParserAvailable': yaml is not None,
        'personalMarkers': 0, 'missingMarkdownLinks': 0,
        'licensedFiles': licensed_count, 'retainedNotices': notice_count,
        'lockedCatalogSources': catalog_source_count, 'sourceArchives': len(locked_archives),
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()
