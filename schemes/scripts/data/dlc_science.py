"""Augment optional science catalogs from a fixed broad metadata snapshot.

SPDX-License-Identifier: GPL-3.0-only
"""
from collections import Counter
from functools import lru_cache
from pathlib import Path
import gzip
import hashlib
import json
import re
import unicodedata

HAN = '\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af\u3007'
HAN_WORD = re.compile('^[' + HAN + ']+$')
JOINERS = re.compile('(?<=[' + HAN + r'])[\u00b7\u30fb\u2027\u2219\-\u2010-\u2015\uff0d\s]+(?=[' + HAN + '])')
QUALIFIER = re.compile(r'\s*(?:\([^()]*\)|\uff08[^\uff08\uff09]*\uff09)\s*$')
LATIN_LETTERS = r'A-Za-z\u00c0-\u00d6\u00d8-\u00f6\u00f8-\u024f\u1e00-\u1eff'
LATIN = re.compile('[' + LATIN_LETTERS + r"]+(?:['\u2019\u02bc][" + LATIN_LETTERS + ']+)*')
ASCII_LATIN = str.maketrans({'\u00c6':'AE','\u00e6':'ae','\u0152':'OE','\u0153':'oe',
    '\u00d8':'O','\u00f8':'o','\u0141':'L','\u0142':'l','\u0110':'D','\u0111':'d',
    '\u00d0':'D','\u00f0':'d','\u00de':'Th','\u00fe':'th','\u00df':'ss',
    '\u0126':'H','\u0127':'h','\u014a':'Ng','\u014b':'ng','\u0166':'T','\u0167':'t','\u0131':'i'})
LANGUAGES = ('zh-hant', 'zh', 'zh-hans')
WEIGHT = 100


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def _member(root, name):
    if not re.fullmatch('[A-Za-z0-9._-]+', name):
        raise ValueError('Invalid science source member')
    path = root / name
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Science source member escapes its directory')
    return path


@lru_cache(maxsize=2)
def _source(directory):
    root = Path(directory)
    manifest = json.loads((root / 'science-source-manifest.json').read_text('utf-8'))
    specification = manifest['snapshot']
    raw = _member(root, specification['file']).read_bytes()
    if len(raw) != specification['bytes'] or sha256(raw) != specification['sha256']:
        raise ValueError('Science snapshot checksum mismatch')
    for record in manifest['original_response_archives'] + manifest['license_files']:
        raw_member = _member(root, record['file']).read_bytes()
        if len(raw_member) != record['bytes'] or sha256(raw_member) != record['sha256']:
            raise ValueError('Science source component checksum mismatch')
    snapshot = json.loads(gzip.decompress(raw))
    if set(snapshot['domains']) != {'math', 'physics'} or snapshot['article_text_included']:
        raise ValueError('Unexpected science snapshot scope')
    for domain, data in snapshot['domains'].items():
        if len(data['articles']) != manifest['domains'][domain]['selected_articles']:
            raise ValueError('Incomplete science article selection')
    return snapshot, manifest, sha256(raw)


def _without_qualifier(value):
    original = value
    while QUALIFIER.search(value):
        value = QUALIFIER.sub('', value)
    return value.strip(), value != original


def _chinese(entity):
    seen = set()
    labels, aliases = entity.get('labels', {}), entity.get('aliases', {})
    for language in LANGUAGES:
        entries = ([labels[language]] if language in labels else []) + aliases.get(language, [])
        for item in entries:
            value = item['value']
            key = value, language == 'zh-hant'
            if key not in seen:
                seen.add(key)
                yield value, language != 'zh-hant'


def _english(entity, article_titles):
    seen = set()
    labels, aliases = entity.get('labels', {}), entity.get('aliases', {})
    values = ([labels[language]['value'] for language in ('en', 'mul') if language in labels]
              + [item['value'] for language in ('en', 'mul') for item in aliases.get(language, [])]
              + sorted(article_titles))
    for value in values:
        if value not in seen:
            seen.add(value)
            yield value


def _tokens(value):
    value, qualifier_removed = _without_qualifier(value)
    for match in LATIN.finditer(value):
        display = unicodedata.normalize('NFC', match.group())
        canonical = ''.join(char for char in unicodedata.normalize('NFKD', display.translate(ASCII_LATIN))
                            if not unicodedata.combining(char))
        canonical = canonical.replace('\u2019', "'").replace('\u02bc', "'").lower()
        if re.fullmatch("[a-z]+(?:'[a-z]+)*", canonical) and len(canonical.replace("'", '')) >= 2:
            yield canonical, display, qualifier_removed


def augment_catalog(sources_dir, domain, reader, base_cn, base_en):
    """Return CN identities, protocol-v1 English rows and source/build counts.

    CN lookup forms join only inter-Han separators and omit trailing title
    qualifiers. The original labels and their versions remain in the snapshot.
    English words retain lower-case canonical identities. Source spelling is a
    display alias; existing base vocabulary still owns duplicate frequencies.
    """
    if domain not in ('math', 'physics'):
        raise ValueError('Unsupported science catalog domain')
    root = Path(sources_dir)
    if not (root / 'science-source-manifest.json').is_file():
        root /= 'science'
    snapshot, manifest, snapshot_hash = _source(str(root.resolve()))
    data = snapshot['domains'][domain]
    entity_titles = {}
    skipped = Counter()
    for article in data['articles']:
        key = article.get('entity')
        if not key:
            skipped['ArticleWithoutEntity'] += 1
            continue
        entity_titles.setdefault(key, set()).add(article['title'])
    cn = set(base_cn)
    base_words = set(base_en)
    english = {word: word for word in sorted(base_words)}
    source_chinese, source_english = set(), set()
    normalization = Counter()
    selected_entities = 0
    for key in sorted(entity_titles, key=lambda item: int(item[1:])):
        entity = snapshot['entities'].get(key)
        if not entity or 'missing' in entity:
            skipped['MissingEntity'] += 1
            continue
        selected_entities += 1
        for original, source_sc in _chinese(entity):
            text = unicodedata.normalize('NFC', original.strip())
            text, removed = _without_qualifier(text)
            joined = JOINERS.sub('', text)
            normalization['TitleQualifierRemoved'] += int(removed)
            normalization['InterHanSeparatorsJoined'] += int(joined != text)
            if not HAN_WORD.fullmatch(joined):
                skipped['NonHanChineseLabel'] += 1
                continue
            result, detail = reader.read(joined, source_sc=source_sc, poetry=False)
            if result is None:
                skipped[detail.get('Reason', 'UnsupportedReading')] += 1
                continue
            if len(result[0]) != len(result[1].split()):
                raise ValueError('Science reading alignment differs from its text')
            source_chinese.add(result)
            normalization['TCTextConversion'] += int(detail.get('NormalizedText', False))
        for form in _english(entity, entity_titles[key]):
            for canonical, display, removed in _tokens(form):
                source_english.add(canonical)
                # First source definition owns display. Base CEDICT words keep
                # their existing ordinary form, as does the runtime base owner.
                english.setdefault(canonical, display)
                normalization['EnglishTokensWithQualifierRemoved'] += int(removed)
    cn.update(source_chinese)
    records = []
    for canonical, display in sorted(english.items()):
        if display == canonical:
            records.append(('word', canonical, canonical, canonical, '-', str(WEIGHT), '1', '-', '-'))
        else:
            records.append(('alias', canonical, canonical, canonical, display, str(WEIGHT), '1', '-', '-'))
        plain = canonical.replace("'", '')
        if plain != canonical:
            records.append(('alias', plain, canonical, canonical, display, str(WEIGHT), '1', '-', '-'))
    # The protocol identity is alias/code/native. Keep one definition per key.
    unique = {}
    for record in records:
        unique.setdefault(record[1:4], record)
    records = sorted(unique.values(), key=lambda row: (row[1], row[2], row[3]))
    report = {'Source': 'Complete public subject-project assessment metadata and versioned Wikidata labels/aliases',
              'SnapshotSha256': snapshot_hash, 'SelectedArticles': len(data['articles']),
              'SelectedEntities': selected_entities, 'ChineseSourceIdentities': len(source_chinese),
              'ChineseOverlapWithBase': len(source_chinese & set(base_cn)),
              'ChineseRows': len(cn), 'EnglishSourceWords': len(source_english),
              'EnglishWords': len(english), 'EnglishRows': len(records),
              'Normalization': dict(sorted(normalization.items())), 'Skipped': dict(sorted(skipped.items())),
              'WeightRule': 'Uniform 100; duplicate base vocabulary retains its original runtime frequency and display owner.',
              'ReadingRule': 'Pinned shared phrase-aware reader; no poetry-specific clause-final reading rule.',
              'ArticleTextIncluded': False}
    return cn, records, report
