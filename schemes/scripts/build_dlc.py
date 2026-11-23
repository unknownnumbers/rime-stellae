#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build optional catalogs from fixed public sources, without network access."""
from __future__ import annotations

import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import unicodedata
import zipfile
import zlib
import shutil
import tempfile
import platform
from data.build_dlc_english_index import add_module_index
from data.dlc_poetry import build_catalog, write_module, archive_module, file_digest
from data.dlc_readings import Readings
from data.dlc_science import augment_catalog

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "dlc" / "sources"
REVISION = "2026.11.14.2"
INDEXED_PACKAGE_VERSION = "2026.11.19"
WEIGHT = 100
POETRY_COMMIT = "b8594f81a89752241442f2ce267d6f66f96704ee"
LUNA_SHA256 = "0397c7741c3347631412f5bd20a6787087ca6c27093a46f216cfc8bb754f285f"
PINS = {
    "cedict_1_0_ts_utf-8_mdbg.txt.gz": "3199822e3cb14dfd13b4c80374cefb6d02e579e92f39e5ac7e6a7fa702fae739",
    "tang-300.json": "d77a145f7470da2ed2f79515944563c062ffc43fceda07f195a36ead66b7e5c7",
    "song-300.json": "ca5d74f7fdb9d5a6acc22a7c8b4395228cad4bb8be53df44c19ba83ab6983b20",
    "chinese-poetry-MIT-LICENSE.txt": "c195319aeaa3ffcbe16aa5d26eec19eae5a42f84337dd2b3dc3c9d5ccbbd6507",
    "CC-BY-SA-4.0.txt": "28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5",
    "allowed-syllables.txt": "ddd9b253b4f3412d17ed1c119d9d3b36f1153e7c3ff7f62e20e59cdfd1856689",
}
DOMAIN_PATTERNS = {
    "math": r"\b(?:math(?:ematics|ematical)?|geometry|geometric|algebra(?:ic)?|statistics|statistical|trigonometry|arithmetic|calculus|topology|probability)\b",
    "physics": r"\b(?:physics|mechanics|optics|electronics|electricity|electrical|electromagnetism|thermodynamics|acoustics)\b",
    "computer": r"\b(?:computing|computers?|programming|software|internet)\b",
}
HAN = r"\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af\u3007"
HAN_WORD = re.compile("^[" + HAN + "]+$")
HAN_CLAUSE = re.compile("[" + HAN + "]+")
ENTRY = re.compile(r"^(\S+) (\S+) \[([^\]]+)\] /(.+)/$")
LABEL = re.compile(r"\(([^()]*)\)")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def read_sources() -> dict[str, bytes]:
    result = {}
    for name, expected in PINS.items():
        data = (SOURCES / name).read_bytes()
        if sha256(data) != expected:
            raise ValueError("Public source checksum mismatch: " + name)
        result[name] = data
    lock_path = SOURCES / 'catalog-source-lock.json'
    lock = json.loads(lock_path.read_text('utf-8'))
    for record in lock['Files']:
        path = (SOURCES / record['Path']).resolve()
        if not path.is_relative_to(SOURCES.resolve()) or path.is_symlink():
            raise ValueError('Invalid fixed catalog source path')
        if path.stat().st_size != record['Bytes'] or file_digest(path) != record['Sha256']:
            raise ValueError('Fixed catalog source differs from its checksum lock')
    return result


def pinyin(raw: str, syllables: set[str]) -> str | None:
    result = []
    for token in raw.split():
        # CEDICT's tone digits distinguish readings from literal Latin letters.
        if not re.search("[1-5]$", token):
            return None
        token = token.lower().replace("u:", "v").replace("ü", "v")
        token = re.sub("[1-5]$", "", token)
        token = "".join(c for c in unicodedata.normalize("NFD", token) if not unicodedata.combining(c))
        if not re.fullmatch("[a-z]+", token) or token not in syllables:
            return None
        result.append(token)
    return " ".join(result) if result else None


def cedict(data: bytes, syllables: set[str]) -> list[dict]:
    result = []
    for line in gzip.decompress(data).decode("utf-8-sig").splitlines():
        if not line or line.startswith("#"):
            continue
        match = ENTRY.fullmatch(line)
        if not match:
            raise ValueError("Unexpected public CC-CEDICT entry format")
        tc, sc, reading, definitions = match.groups()
        result.append({"text": tc, "sc": sc, "code": pinyin(reading, syllables),
                       "glosses": definitions.split("/"), "labels": LABEL.findall(definitions)})
    if len(result) != 125412:
        raise ValueError("Unexpected fixed CC-CEDICT entry count")
    return result


def without_parentheses(gloss: str) -> str:
    while LABEL.search(gloss):
        gloss = LABEL.sub("", gloss)
    return gloss.strip()


def domain_catalog(entries: list[dict], domain: str) -> tuple[set[tuple[str, str]], set[str], dict]:
    pattern = re.compile(DOMAIN_PATTERNS[domain], re.I)
    selected, cn, en, skipped = 0, set(), set(), Counter()
    for entry in entries:
        matching_labels = [label for label in entry["labels"]
                           if pattern.search(label) and not (domain == "computer" and re.search(r"\binternet slang\b", label, re.I))]
        if not matching_labels:
            continue
        selected += 1
        if not HAN_WORD.fullmatch(entry["text"]):
            skipped["NonHanHeadword"] += 1
        elif not entry["code"]:
            skipped["UnsupportedReading"] += 1
        else:
            cn.add((entry["text"], entry["code"]))
        for gloss in entry["glosses"]:
            word = without_parentheses(gloss)
            if re.fullmatch("[A-Za-z]+", word):
                en.add(word.lower())
    return cn, en, {"SelectedSourceEntries": selected, "Skipped": dict(sorted(skipped.items())),
                    "ChineseRows": len(cn), "EnglishRows": len(en), "DomainPattern": DOMAIN_PATTERNS[domain]}


def reading_trie(entries: list[dict], source_form: str) -> dict:
    trie = {}
    primary, secondary = ("sc", "text") if source_form == "SC" else ("text", "sc")
    for key in (primary, secondary):
        for entry in entries:
            if not entry["code"] or not HAN_WORD.fullmatch(entry["text"]) or not HAN_WORD.fullmatch(entry[key]):
                continue
            branch = trie
            for char in entry[key]:
                branch = branch.setdefault(char, {})
            # Retain the first supported reading in the pinned source's own order.
            branch.setdefault("", (entry["text"], entry["code"]))
    return trie


def clause_reading(text: str, trie: dict) -> tuple[str, str] | None:
    # Longest complete cover. A shorter match is used only if the longer path
    # leaves a suffix that cannot be encoded from the same public dictionary.
    resolved: dict[int, tuple[str, str]] = {len(text): ("", "")}
    for start in range(len(text) - 1, -1, -1):
        branch, matches = trie, []
        for end in range(start, len(text)):
            branch = branch.get(text[end])
            if branch is None:
                break
            if "" in branch and end + 1 in resolved:
                suffix_text, suffix_code = resolved[end + 1]
                tc, code = branch[""]
                matches.append((tc + suffix_text, code + (" " + suffix_code if suffix_code else "")))
        if matches:
            resolved[start] = matches[-1]
    return resolved.get(0)


def poetry_catalog(sources: dict[str, bytes], entries: list[dict]) -> tuple[set[tuple[str, str]], dict]:
    words, report = set(), {}
    for name, source_form in (("tang-300.json", "TC"), ("song-300.json", "SC")):
        trie = reading_trie(entries, source_form)
        anthology = json.loads(sources[name])
        clauses = encoded = skipped = 0
        for poem in anthology:
            for paragraph in poem["paragraphs"]:
                # The Tang snapshot brackets eight individual poem characters.
                # Keep those characters in their clause instead of splitting it.
                paragraph = paragraph.replace("[", "").replace("]", "")
                for text in HAN_CLAUSE.findall(paragraph):
                    clauses += 1
                    result = clause_reading(text, trie)
                    if result is None:
                        skipped += 1
                    else:
                        words.add(result)
                        encoded += 1
        report[name] = {"Works": len(anthology), "SourceForm": source_form, "Clauses": clauses,
                        "EncodedClauses": encoded, "UnencodedClauses": skipped}
    report["ChineseRows"], report["EnglishRows"] = len(words), 0
    report["ClauseRule"] = "Han clauses; ASCII square brackets removed while retaining their enclosed characters"
    report["ReadingRule"] = "CC-CEDICT source-order readings and TC headwords; longest complete word cover; unencodable clauses omitted"
    report["ReadingReview"] = "Automatically annotated; not reviewed line by line"
    return words, report


def source_records(domain: str) -> list[dict]:
    records = [{"File": "cedict_1_0_ts_utf-8_mdbg.txt.gz", "Sha256": PINS["cedict_1_0_ts_utf-8_mdbg.txt.gz"],
                "Publisher": "MDBG / CC-CEDICT contributors", "Snapshot": "2026-11-13T04:51:32Z",
                "License": "CC-BY-SA-4.0", "Url": "https://www.mdbg.net/chinese/dictionary?page=cedict"},
               {"File": "allowed-syllables.txt", "Sha256": PINS["allowed-syllables.txt"],
                "Purpose": "Native dictionary syllable compatibility", "SourceFile": "config/pc/luna_pinyin.dict.yaml",
                "SourceSha256": LUNA_SHA256, "SourceLicense": "LGPL-3.0"}]
    if domain == "poetry":
        for name, upstream in (("tang-300.json", "全唐诗/唐诗三百首.json"), ("song-300.json", "宋词/宋词三百首.json")):
            records.append({"File": name, "Sha256": PINS[name], "License": "MIT", "Commit": POETRY_COMMIT,
                            "Url": "https://raw.githubusercontent.com/chinese-poetry/chinese-poetry/" + POETRY_COMMIT + "/" + upstream})
    return records


def module_files(domain: str, cn: set[tuple[str, str]], en: set[str], report: dict,
                 sources: dict[str, bytes], english_records=None) -> dict[str, bytes]:
    packs = ([f"rymcp_dlc_poetry_{i:02d}" for i in range(32)] if domain == "poetry"
             else ["rymcp_dlc_" + domain])
    activation = ("patch:\n  __include: rymcp_dlc/poetry/words_00.dict:/activation\n"
                  if domain == "poetry" else "patch:\n  translator/packs/+:\n"
                  + "".join("    - " + pack + "\n" for pack in packs))
    header = ("---\nname: rymcp_dlc/" + domain + "/words\nversion: '" + REVISION
              + "'\nsort: by_weight\nuse_preset_vocabulary: false\n" + activation + "...\n")
    dictionary = header + "".join(f"{text}\t{code}\t{WEIGHT}\n" for text, code in sorted(cn))
    files = {"words.dict.yaml": dictionary.encode("utf-8"),
             "LICENSE-CC-BY-SA-4.0.txt": sources["CC-BY-SA-4.0.txt"]}
    if domain == "poetry":
        ordered = sorted(cn, key=lambda item: (item[1], item[0]))
        for i in range(32):
            name = f"words_{i:02d}"
            activation = (f"activation:\n  __include: rymcp_dlc/poetry/words_{i + 1:02d}.dict:/activation\n"
                          if i < 31 else "activation:\n  translator/packs/+:\n"
                          + "".join("    - " + pack + "\n" for pack in packs))
            shard_header = (f"---\nname: rymcp_dlc/poetry/{name}\nversion: '{REVISION}'\n"
                            "sort: by_weight\nuse_preset_vocabulary: false\n" + activation + "...\n")
            rows = ordered[len(ordered) * i // 32:len(ordered) * (i + 1) // 32]
            files[name + ".dict.yaml"] = (shard_header + "".join(
                f"{text}\t{code}\t{WEIGHT}\n" for text, code in rows)).encode("utf-8")
        report["NativeTableShards"] = 32
        report["ShardRule"] = "Sort by canonical code, then text; continuous slices at floor(N*i/32)"
        report["ActivationRule"] = "Required header include chain through all 32 shards"
    if en:
        if english_records is None:
            files["english.tsv"] = ("format\t1\n" + "".join(
                f"word\t{word}\t{word}\t{word}\t-\t{WEIGHT}\t1\t-\t-\n" for word in sorted(en))).encode("ascii")
        else:
            files['english.tsv'] = ('format\t1\n' + ''.join('\t'.join(row) + '\n' for row in english_records)).encode('utf-8')
    if domain == "poetry":
        files["LICENSE-chinese-poetry-MIT.txt"] = sources["chinese-poetry-MIT-LICENSE.txt"]
    notice = ("CC-CEDICT: community maintained by CC-CEDICT contributors, published by MDBG.\n"
              "Original CEDICT: Copyright (C) 1997, 1998 Paul Andrew Denisowski.\n"
              "Source: https://www.mdbg.net/chinese/dictionary?page=cedict\n"
              "Derived catalog and reading annotations: CC BY-SA 4.0.\n"
              "Changes: systematic domain extraction or anthology annotation, tone removal,\n"
              "native-syllable filtering, deduplication, and a uniform weight of 100.\n")
    if domain == "poetry":
        notice += ("Poetry text: chinese-poetry/chinese-poetry, fixed commit " + POETRY_COMMIT + ".\n"
                   "The upstream MIT notice is included unchanged.\n"
                   "The automatic reading annotations have not been reviewed line by line.\n")
    files["NOTICE.txt"] = notice.encode("utf-8")
    files["SOURCE.json"] = encode_json({"Format": 1, "Id": domain, "Revision": REVISION,
                                       "DataLicense": "CC-BY-SA-4.0", "UniformWeight": WEIGHT,
                                       "Sources": source_records(domain), "Build": report})
    if domain in ('math', 'physics'):
        source = json.loads(files['SOURCE.json'])
        science = json.loads((SOURCES / 'science/science-source-manifest.json').read_text('utf-8'))
        source['Sources'].append({'File': 'science/science-source-manifest.json',
                                  'Sha256': file_digest(SOURCES / 'science/science-source-manifest.json'),
                                  'Snapshot': science['snapshot'], 'Providers': science['sources']})
        source['Sources'].append({'File': 'readings/pypinyin-source.json',
                                  'Sha256': file_digest(SOURCES / 'readings/pypinyin-source.json'),
                                  'License': 'MIT'})
        source['Sources'].append({'File': 'readings/opencc/source.json',
                                  'Sha256': file_digest(SOURCES / 'readings/opencc/source.json'),
                                  'License': 'Apache-2.0',
                                  'Purpose': 'Fixed dictionary-based text conversion'})
        source['Sources'].append({'File': 'readings/Unihan-17.0.0.zip',
                                  'Sha256': file_digest(SOURCES / 'readings/Unihan-17.0.0.zip'),
                                  'Version': '17.0.0', 'License': 'Unicode-3.0',
                                  'Purpose': 'Original-character fallback readings'})
        files['SOURCE.json'] = encode_json(source)
        for relative, name in (
            ('science/CC0-1.0-legalcode.txt', 'LICENSE-Wikidata-CC0.txt'),
            ('science/SCIENCE-NOTICE.txt', 'NOTICE-science-sources.txt'),
            ('readings/pypinyin-LICENSE.txt', 'LICENSE-pypinyin-MIT.txt'),
            ('readings/opencc/LICENSE', 'LICENSE-OpenCC-Apache-2.0.txt'),
            ('readings/opencc/AUTHORS', 'AUTHORS-OpenCC.txt'),
            ('readings/UNICODE-LICENSE-V3.txt', 'LICENSE-Unicode-3.0.txt'),
        ):
            files[name] = (SOURCES / relative).read_bytes()
    manifest = ["format\t1", "id\t" + domain, "revision\t" + REVISION,
                "languages\t" + ("cn,en" if en else "cn")]
    for name, data in sorted(files.items()):
        manifest.append(f"file\t{name}\t{len(data)}\t{zlib.adler32(data) & 0xffffffff:08x}")
    files["manifest.tsv"] = ("\n".join(manifest) + "\n").encode("utf-8")
    return files


def archive(files: dict[str, bytes], domain: str, path: Path) -> bytes:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as target:
        for relative, data in sorted(files.items()):
            info = zipfile.ZipInfo("rymcp_dlc/" + domain + "/" + relative, (2026, 11, 14, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(info, data)
    return path.read_bytes()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "out" / "dlc" / "modules")
    parser.add_argument("--archive-dir", "--archives", dest="archives", type=Path, default=ROOT / "out" / "dlc")
    parser.add_argument('--domain', choices=('all', 'math', 'physics', 'computer', 'poetry'), default='all')
    parser.add_argument('--version', help='Override archive filename version without changing module revisions or weights')
    args = parser.parse_args()
    if args.version and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.version):
        parser.error('Invalid archive version')
    sources = read_sources()
    syllables = set(sources["allowed-syllables.txt"].decode("ascii").splitlines())
    entries = cedict(sources["cedict_1_0_ts_utf-8_mdbg.txt.gz"], syllables) if args.domain != 'poetry' else []
    report_path = args.output / 'build-report.json'
    builds = {}
    if report_path.exists():
        prior = json.loads(report_path.read_text('utf-8'))
        if prior['Revision'] != REVISION:
            raise ValueError('Choose a fresh output directory for this catalog version')
        builds.update(prior['Modules'])
    domains = ('math', 'physics', 'computer', 'poetry') if args.domain == 'all' else (args.domain,)
    for domain in domains:
        english_records = None
        if domain == "poetry":
            connection, report = build_catalog(SOURCES, args.output.parent / 'work' / 'poetry', syllables, progress=True)
            if report['ChineseRows'] < 2800000 or report['Readings'].get('UnsupportedReading', 0) > report['Readings']['InputClauses'] * 0.005:
                raise ValueError('Full poetry coverage and reading checks failed')
            directory = args.output / 'rymcp_dlc' / domain
            write_module(connection, report, SOURCES, directory, REVISION, WEIGHT)
            archive_version = args.version or REVISION
            artifact = archive_module(directory, args.archives / f'stellae-dlc-{domain}-{archive_version}.zip')
            builds[domain] = {'ChineseRows': report['ChineseRows'], 'EnglishRows': 0, **artifact,
                              'ArchiveVersion': archive_version, 'Build': report}
            continue
        else:
            cn, en, report = domain_catalog(entries, domain)
            if domain in ('math', 'physics'):
                work = args.output.parent / 'work'
                work.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(prefix='science-pinyin-', dir=work) as temporary:
                    with zipfile.ZipFile(SOURCES / 'readings/pypinyin-0.55.0-py2.py3-none-any.whl') as dependency_archive:
                        target = Path(temporary).resolve()
                        if not all((target / name).resolve().is_relative_to(target) for name in dependency_archive.namelist()):
                            raise ValueError('Invalid pinned dependency member')
                        dependency_archive.extractall(target)
                    reader = Readings(Path(temporary), SOURCES / 'readings/opencc', syllables)
                    cn, english_records, broader = augment_catalog(SOURCES, domain, reader, cn, en)
                en = {record[2] for record in english_records}
                report = {'CC-CEDICT': report, 'BroaderPublicSources': broader,
                          'ChineseRows': len(cn), 'EnglishRows': len(english_records), 'EnglishWords': len(en)}
        if not cn:
            raise ValueError("Empty Chinese catalog: " + domain)
        files = module_files(domain, cn, en, report, sources, english_records)
        files, english_index = add_module_index(files)
        directory = args.output / "rymcp_dlc" / domain
        existing = {str(p.relative_to(directory)).replace("\\", "/") for p in directory.rglob("*") if p.is_file()}
        if existing - files.keys():
            raise ValueError("Unexpected files in output catalog; choose a clean output directory")
        for relative, data in files.items():
            target = directory / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        archive_version = args.version or INDEXED_PACKAGE_VERSION
        filename = f"stellae-dlc-{domain}-{archive_version}.zip"
        data = archive(files, domain, args.archives / filename)
        builds[domain] = {"ChineseRows": len(cn), "EnglishRows": len(english_records) if english_records is not None else len(en),
                          "EnglishWords": len(en), "Zip": filename,
                          "Bytes": len(data), "Sha256": sha256(data), "ArchiveVersion": archive_version, "Build": report,
                          "EnglishIndex": english_index}
    summary = {"Format": 2, "Revision": REVISION, "SourceSha256": PINS,
               'CatalogSourceLockSha256': file_digest(SOURCES / 'catalog-source-lock.json'),
               'Compression': 'ZIP deflate; fixed member order and metadata.',
               'BuildEnvironment': {'Python': platform.python_version(), 'Zlib': zlib.ZLIB_RUNTIME_VERSION},
               "Modules": builds}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "build-report.json").write_bytes(encode_json(summary))
    print(json.dumps(summary, ensure_ascii=True, sort_keys=True))


if __name__ == "__main__":
    main()
