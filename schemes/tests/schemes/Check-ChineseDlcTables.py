#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify complete DLC source streams against compiled Rime table code/text.

Requires test-only marisa-trie==1.3.1. Index layouts follow librime table.h
and mapped_file.h. Expected rows stream; only one native shard is decoded.
"""
import argparse
import hashlib
import heapq
import itertools
import json
from pathlib import Path
import struct
import sqlite3
import tempfile

import marisa_trie


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def entries(path, ordered=True):
    """Yield ((code, text), weight), optionally requiring source ordering."""
    with path.open(encoding="utf-8-sig") as source:
        for line in source:
            if line.rstrip("\r\n") == "...":
                break
        else:
            raise ValueError(f"Missing dictionary header: {path.name}")
        previous = None
        for line in source:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 3 or not all(fields):
                raise ValueError(f"Malformed dictionary row: {path.name}")
            text, code, weight = fields
            identity = (code, text)
            if ordered and previous is not None and identity <= previous:
                raise ValueError(f"Unsorted or repeated source identity: {path.name}")
            previous = identity
            yield identity, weight


def sorted_entries(path):
    """Externally sort legacy catalogs, keeping memory independent of rows."""
    with tempfile.TemporaryDirectory(prefix="rime-dlc-check-") as directory:
        db = sqlite3.connect(str(Path(directory) / "rows.sqlite3"))
        try:
            db.execute("CREATE TABLE rows(code TEXT, text TEXT, weight TEXT, "
                       "PRIMARY KEY(code, text)) WITHOUT ROWID")
            db.executemany("INSERT INTO rows VALUES(?,?,?)",
                           ((code, text, weight) for (code, text), weight
                            in entries(path, ordered=False)))
            for code, text, weight in db.execute("SELECT code,text,weight FROM rows ORDER BY code,text"):
                yield (code, text), weight
        finally:
            db.close()


def metadata(path):
    result = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        fields = line.split("\t")
        if fields[0] != "file":
            if len(fields) != 2 or fields[0] in result:
                raise ValueError("Invalid manifest metadata")
            result[fields[0]] = fields[1]
    if result.get("format") not in ("1", "2"):
        raise ValueError("Unsupported manifest format")
    return result


def native_entries(data):
    """Decode v4 relative indices and MARISA strings without a live schema."""
    if len(data) < 68 or data[:32].split(b"\0", 1)[0] != b"Rime::Table/4.0":
        raise ValueError("Unsupported compiled table layout")

    def bounds(offset, size):
        if offset < 0 or size < 0 or offset + size > len(data):
            raise ValueError("Compiled index points outside its image")
        return offset

    def u32(offset):
        return struct.unpack_from("<I", data, bounds(offset, 4))[0]

    def pointer(offset, nullable=False):
        relative = struct.unpack_from("<i", data, bounds(offset, 4))[0]
        if not relative:
            if nullable:
                return None
            raise ValueError("Missing compiled index pointer")
        return bounds(offset + relative, 0)

    image_start, image_size = pointer(60), u32(64)
    if image_start < 68 or image_size < 1 or image_start + image_size != len(data):
        raise ValueError("Compiled string table is incomplete")
    strings = marisa_trie.Trie().frombytes(data[image_start:])
    syllabary_at = pointer(44)
    n_syllables = u32(syllabary_at)
    bounds(syllabary_at + 4, n_syllables * 4)
    syllabary = [strings.restore_key(u32(syllabary_at + 4 + 4 * i))
                 for i in range(n_syllables)]
    if n_syllables != u32(36) or syllabary != sorted(set(syllabary)):
        raise ValueError("Invalid compiled syllabary")

    def row(entry_at, code):
        bounds(entry_at, 8)
        if not code or any(i < 0 or i >= n_syllables for i in code):
            raise ValueError("Invalid compiled syllable id")
        return (" ".join(syllabary[i] for i in code), strings.restore_key(u32(entry_at)))

    def entry_list(list_at, code):
        count = u32(list_at)
        if count:
            start = pointer(list_at + 4)
            bounds(start, 8 * count)
            for i in range(count):
                yield row(start + i * 8, code)

    def walk(index_at, prefix):
        count = u32(index_at)
        if len(prefix) == 3:
            bounds(index_at + 4, count * 16)
            for i in range(count):
                at = index_at + 4 + i * 16
                extra_size = u32(at)
                extra_at = pointer(at + 4) if extra_size else None
                if extra_size > 256:
                    raise ValueError("Implausible compiled code length")
                if extra_size:
                    bounds(extra_at, 4 * extra_size)
                extra = tuple(u32(extra_at + j * 4) for j in range(extra_size))
                yield row(at + 8, prefix + extra)
            return
        stride = 12 if not prefix else 16
        bounds(index_at + 4, count * stride)
        for i in range(count):
            at = index_at + 4 + i * stride
            code = prefix + (i if not prefix else u32(at),)
            list_at = at if not prefix else at + 4
            yield from entry_list(list_at, code)
            next_at = pointer(list_at + 8, nullable=True)
            if next_at is not None:
                yield from walk(next_at, code)

    rows = sorted(walk(pointer(48), ()))
    if len(rows) != u32(40) or any(a >= b for a, b in itertools.pairwise(rows)):
        raise ValueError("Repeated or missing compiled entries")
    return rows, n_syllables, image_size


def check(build_dir, modules_dir):
    reports, modules = [], []
    for module_id in ("math", "physics", "computer", "poetry"):
        module = modules_dir / module_id
        if not module.exists():
            continue
        manifest = metadata(module / "manifest.tsv")
        catalog_path = module / "words.dict.yaml"
        pieces = sorted(module.glob("words_[0-9][0-9].dict.yaml"))
        sharded = bool(pieces)
        if sharded and (module_id != "poetry" or len(pieces) != 32):
            raise ValueError("Unexpected table partition")
        is_v2 = manifest["format"] == "2"
        if is_v2 and (not sharded or manifest.get("cn-layout") != "shards"
                      or next(entries(catalog_path), None) is not None):
            raise ValueError("Format 2 requires a header-only master and 32 shards")
        if not pieces:
            pieces = [catalog_path]
        previous, total = None, 0
        for piece in pieces:
            suffix = "" if piece == catalog_path else "_" + piece.name[6:8]
            name = "rymcp_dlc_" + module_id + suffix
            binary = build_dir / (name + ".table.bin")
            data = binary.read_bytes()
            actual, syllables, image_size = native_entries(data)
            count = len(actual)
            initial_capacity = 4096 + 32 * syllables + 64 * count
            if count < 1 or syllables < 1 or len(data) > initial_capacity:
                raise ValueError("Empty table or compiled table exceeded initial allocation")
            source_count = 0
            sentinel = object()
            expected_rows = entries(piece) if is_v2 else sorted_entries(piece)
            for expected, decoded in itertools.zip_longest(expected_rows, actual, fillvalue=sentinel):
                if expected is sentinel or decoded is sentinel or expected[0] != decoded:
                    raise ValueError(f"Compiled code/text differs from source: {name}")
                identity = expected[0]
                if is_v2 and previous is not None and identity <= previous:
                    raise ValueError("Partition union is not globally strict (code, text) order")
                previous = identity
                source_count += 1
            total += source_count
            reports.append({
                "pack": name, "entries": count, "syllables": syllables,
                "initial_capacity": initial_capacity, "bytes": len(data),
                "string_image_bytes": image_size, "exact_code_text": True,
                "sha256": hashlib.sha256(data).hexdigest(),
                "source_sha256": sha256(piece),
            })
            del actual, data
        if sharded and not is_v2:
            # Legacy partitions can follow text order. Merge external sorts
            # rather than imposing the format 2 ordering rule on format 1.
            union = heapq.merge(*(sorted_entries(piece) for piece in pieces), key=lambda row: row[0])
            sentinel, previous = object(), None
            for whole, part in itertools.zip_longest(sorted_entries(catalog_path), union, fillvalue=sentinel):
                if whole is sentinel or part is sentinel or whole != part:
                    raise ValueError("Legacy partition union differs from complete master")
                if previous is not None and part[0] <= previous:
                    raise ValueError("Repeated identity across legacy partitions")
                previous = part[0]
        if is_v2 and total != int(manifest.get("cn-rows", "-1")):
            raise ValueError("Partition union differs from declared cn-rows")
        modules.append({"id": module_id, "manifest_format": int(manifest["format"]),
                        "entries": total, "partitions": len(pieces)})
    if not reports:
        raise ValueError("No optional source catalogs were found")
    return {"format": "chinese-dlc-table-check-v2", "passed": True,
            "exact_code_text": True, "modules": modules, "tables": reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--modules-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = check(args.build_dir.resolve(), args.modules_dir.resolve())
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": True, "tables": len(result["tables"]),
                      "entries": sum(row["entries"] for row in result["tables"])}))


if __name__ == "__main__":
    main()
