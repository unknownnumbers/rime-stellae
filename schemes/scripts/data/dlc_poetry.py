"""Build a complete fixed-source verse catalog without retaining it in memory.

SPDX-License-Identifier: GPL-3.0-only
"""
from collections import Counter
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import zipfile
import zlib

from .poetry_cleaner import anthology_works, clean_poem
from .dlc_readings import Readings


def file_digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n',
                          encoding='utf-8', newline='\n')


def source_records(folder):
    main = json.loads((folder / 'poetry/source-manifest.json').read_text('utf-8'))
    companion = json.loads((folder / 'poetry/variant-source-manifest.json').read_text('utf-8'))
    groups = main['groups']
    sources = [{'File': 'poetry/' + group['archive'], 'Sha256': group['archive_sha256'],
                'Commit': main['commit'], 'Works': group['works'], 'License': 'MIT'}
               for group in groups.values()]
    sources.append({'File': 'poetry/' + companion['source_archive']['path'],
                    'Sha256': companion['source_archive']['sha256'], 'Commit': companion['commit'],
                    'License': 'MIT', 'Purpose': 'Complete companion anthologies and text variants'})
    sources.append({'File': 'readings/pypinyin-0.55.0-py2.py3-none-any.whl',
                    'Sha256': file_digest(folder / 'readings/pypinyin-0.55.0-py2.py3-none-any.whl'),
                    'Version': '0.55.0', 'License': 'MIT'})
    sources.append({'File': 'readings/opencc/source.json',
                    'Sha256': file_digest(folder / 'readings/opencc/source.json'),
                    'License': 'Apache-2.0', 'Purpose': 'Fixed dictionary-based text conversion'})
    sources.append({'File': 'readings/Unihan-17.0.0.zip',
                    'Sha256': file_digest(folder / 'readings/Unihan-17.0.0.zip'),
                    'Version': '17.0.0', 'License': 'Unicode-3.0',
                    'Purpose': 'Original-character fallback readings'})
    return sources


def iter_sources(folder):
    main = json.loads((folder / 'poetry/source-manifest.json').read_text('utf-8'))
    companion = json.loads((folder / 'poetry/variant-source-manifest.json').read_text('utf-8'))
    with ExitStack() as stack:
        archives = {}
        for name, spec in main['groups'].items():
            path = folder / 'poetry' / spec['archive']
            if file_digest(path) != spec['archive_sha256']:
                raise ValueError('Fixed corpus archive checksum differs')
            archives[name] = stack.enter_context(zipfile.ZipFile(path))
        path = folder / 'poetry' / companion['source_archive']['path']
        if file_digest(path) != companion['source_archive']['sha256']:
            raise ValueError('Companion corpus checksum differs')
        archives['companion'] = stack.enter_context(zipfile.ZipFile(path))
        inputs = []
        for record in main['files']:
            relative = record['path']
            group = 'song-ci' if relative.startswith('宋词/') else ('tang-poems' if '/poet.tang.' in relative else 'song-poems')
            inputs.append((group, record))
        inputs.extend(('companion', record) for record in companion['files'] if record['path'].endswith('.json'))
        for group, record in inputs:
            raw = archives[group].read(record['path'])
            if len(raw) != record['bytes'] or hashlib.sha256(raw).hexdigest() != record['sha256']:
                raise ValueError('Fixed corpus member checksum differs')
            blob = b'blob ' + str(len(raw)).encode('ascii') + b'\0' + raw
            if hashlib.sha1(blob).hexdigest() != record['git_blob_sha1']:
                raise ValueError('Fixed corpus member Git identity differs')
            for poem in anthology_works(json.loads(raw)):
                yield group, record['path'], poem['paragraphs']


def build_catalog(folder, work, syllables, progress=False):
    work.mkdir(parents=True, exist_ok=True)
    database = work / 'poetry.sqlite3'
    if database.exists():
        raise ValueError('Use a fresh poetry build directory')
    connection = sqlite3.connect(database)
    connection.execute('PRAGMA journal_mode=OFF')
    connection.execute('PRAGMA synchronous=OFF')
    connection.execute('CREATE TABLE input(text TEXT PRIMARY KEY,source_sc INTEGER NOT NULL) WITHOUT ROWID')
    connection.execute('CREATE TABLE words(code TEXT NOT NULL,text TEXT NOT NULL,PRIMARY KEY(code,text)) WITHOUT ROWID')
    groups, decisions, reviews = {}, Counter(), Counter()
    batch = []
    for group, source_path, paragraphs in iter_sources(folder):
        group_counts = groups.setdefault(group, Counter())
        group_counts['Works'] += 1
        rows, counts, issues = clean_poem(paragraphs)
        decisions.update(counts)
        reviews.update(issue['reason'] for issue in issues)
        group_counts['Clauses'] += len(rows)
        source_sc = int(source_path.startswith('宋词/'))
        batch.extend((row['text'], source_sc) for row in rows)
        if len(batch) >= 20000:
            connection.executemany('INSERT INTO input VALUES(?,?) ON CONFLICT(text) DO UPDATE SET source_sc=MIN(source_sc,excluded.source_sc)', batch)
            batch.clear()
            connection.commit()
    if batch:
        connection.executemany('INSERT INTO input VALUES(?,?) ON CONFLICT(text) DO UPDATE SET source_sc=MIN(source_sc,excluded.source_sc)', batch)
    connection.commit()
    reading_counts, unknown = Counter(), Counter()
    with tempfile.TemporaryDirectory(prefix='pinyin-', dir=work) as temporary:
        wheel = folder / 'readings/pypinyin-0.55.0-py2.py3-none-any.whl'
        target = Path(temporary).resolve()
        with zipfile.ZipFile(wheel) as archive:
            if not all((target / name).resolve().is_relative_to(target) for name in archive.namelist()):
                raise ValueError('Invalid pinned dependency member')
            archive.extractall(target)
        reader = Readings(target, folder / 'readings/opencc', syllables)
        for text, source_sc in connection.execute('SELECT text,source_sc FROM input ORDER BY text'):
            value, flags = reader.read(text, source_sc=bool(source_sc))
            reading_counts['InputClauses'] += 1
            if value is None:
                reading_counts[flags['Reason']] += 1
                if 'Character' in flags:
                    unknown[f"U+{ord(flags['Character']):04X}"] += 1
            else:
                body, code = value
                connection.execute('INSERT OR IGNORE INTO words VALUES(?,?)', (code, body))
                reading_counts['EncodedClauses'] += 1
                reading_counts['NormalizedText'] += flags['NormalizedText']
                reading_counts['ContextualFinalReturn'] += flags['FinalReturnRule']
                reading_counts['OriginalCharacterFallbacks'] += flags['OriginalCharacterFallbacks']
                reading_counts['UnicodeCharacterFallbacks'] += flags['UnicodeCharacterFallbacks']
            if reading_counts['InputClauses'] % 100000 == 0:
                connection.commit()
                if progress:
                    print(json.dumps({'PoetryClausesChecked': reading_counts['InputClauses']}), flush=True)
    connection.commit()
    count = connection.execute('SELECT COUNT(*) FROM words').fetchone()[0]
    report = {'ChineseRows': count, 'EnglishRows': 0, 'Groups': {key: dict(value) for key, value in groups.items()},
              'CleaningDecisions': dict(sorted(decisions.items())), 'ReviewFlags': dict(sorted(reviews.items())),
              'Readings': dict(reading_counts), 'UnsupportedCharacters': dict(sorted(unknown.items())),
              'ReadingReview': 'Phrase-aware automatic annotation, bounded contextual rules, alignment and native-syllable checks; not reviewed line by line.',
              'VariantRule': 'Complete companion anthologies plus explicitly aligned source variants; ambiguous editorial fragments retain review flags.',
              'CatalogLayout': 'Header-only activation file and 32 code/text-ordered shards; no duplicate complete text catalog.',
              'NativeTableShards': 32}
    return connection, report


def header(name, version, activation):
    return (f"---\nname: rymcp_dlc/poetry/{name}\nversion: '{version}'\nsort: by_weight\n"
            + 'use_preset_vocabulary: false\n' + activation + '...\n')


def write_module(connection, report, sources, directory, version, weight):
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise ValueError('Use a fresh generated poetry module directory')
    packs = [f'rymcp_dlc_poetry_{index:02d}' for index in range(32)]
    master = header('words', version, 'patch:\n  __include: rymcp_dlc/poetry/words_00.dict:/activation\n')
    (directory / 'words.dict.yaml').write_text(master, encoding='utf-8', newline='\n')
    cursor = iter(connection.execute('SELECT code,text FROM words ORDER BY code,text'))
    count = report['ChineseRows']
    for index in range(32):
        activation = (f'activation:\n  __include: rymcp_dlc/poetry/words_{index+1:02d}.dict:/activation\n' if index < 31 else
                      'activation:\n  translator/packs/+:\n' + ''.join('    - ' + pack + '\n' for pack in packs))
        with (directory / f'words_{index:02d}.dict.yaml').open('w', encoding='utf-8', newline='\n') as stream:
            stream.write(header(f'words_{index:02d}', version, activation))
            for _ in range(count * (index + 1) // 32 - count * index // 32):
                code, text = next(cursor)
                stream.write(f'{text}\t{code}\t{weight}\n')
    notices = [('CC-BY-SA-4.0.txt', 'LICENSE-CC-BY-SA-4.0.txt'),
               ('poetry/LICENSE', 'LICENSE-chinese-poetry-MIT.txt'),
               ('readings/pypinyin-LICENSE.txt', 'LICENSE-pypinyin-MIT.txt'),
               ('readings/opencc/LICENSE', 'LICENSE-OpenCC-Apache-2.0.txt'),
               ('readings/opencc/AUTHORS', 'AUTHORS-OpenCC.txt')]
    notices.append(('readings/UNICODE-LICENSE-V3.txt', 'LICENSE-Unicode-3.0.txt'))
    for relative, name in notices:
        shutil.copyfile(sources / relative, directory / name)
    notice = ('Poetry: chinese-poetry/chinese-poetry, fixed public corpus and complete companion anthologies.\n'
              'Original MIT notice and exact source records accompany the source snapshot.\n'
              'Reading software/data: pypinyin 0.55.0 (MIT); fixed OpenCC dictionaries (Apache-2.0).\n'
              'Additional original-character readings: Unicode Unihan 17.0.0 (Unicode-3.0).\n'
              'Generated catalog and reading annotations: CC BY-SA 4.0.\n'
              'Automatic readings use phrase and bounded context rules, without tone marks.\n'
              'Editorial notes and unresolved characters are excluded with recorded counts.\n')
    (directory / 'NOTICE.txt').write_text(notice, encoding='ascii', newline='\n')
    write_json(directory / 'SOURCE.json', {'Format': 2, 'Id': 'poetry', 'Revision': version,
                                          'DataLicense': 'CC-BY-SA-4.0', 'UniformWeight': weight,
                                          'Sources': source_records(sources), 'Build': report})
    manifest = ['format\t2', 'id\tpoetry', 'revision\t' + version, 'languages\tcn',
                'cn-layout\tshards', 'cn-rows\t' + str(count)]
    for path in sorted(directory.iterdir(), key=lambda value: value.name):
        checksum = 1
        with path.open('rb') as stream:
            while block := stream.read(1024 * 1024):
                checksum = zlib.adler32(block, checksum)
        manifest.append(f'file\t{path.name}\t{path.stat().st_size}\t{checksum & 0xffffffff:08x}')
    (directory / 'manifest.tsv').write_text('\n'.join(manifest) + '\n', encoding='utf-8', newline='\n')
    connection.close()


def archive_module(directory, output, domain='poetry'):
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(directory.iterdir(), key=lambda value: value.name):
            info = zipfile.ZipInfo(f'rymcp_dlc/{domain}/{path.name}', (2026, 11, 14, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with archive.open(info, 'w') as stream, path.open('rb') as source:
                shutil.copyfileobj(source, stream, 1024 * 1024)
    return {'Bytes': output.stat().st_size, 'Sha256': file_digest(output), 'Zip': output.name}
